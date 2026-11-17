import Foundation
import QuartzCore
import UIKit

/// Glue between sensors, the dead reckoner, the router and the UI. Everything here runs on the
/// main queue except route calculation.
final class NavigationEngine: ObservableObject {
    // What the UI shows
    @Published private(set) var position: Coord?
    @Published private(set) var heading = 0.0
    @Published private(set) var speedMph = 0.0
    @Published private(set) var limitMph: Int?
    @Published private(set) var overLimit = false
    @Published private(set) var roadName = ""
    @Published private(set) var uncertainty = 0.0
    @Published private(set) var lost = false
    @Published private(set) var cameraTracking = false
    @Published private(set) var route: Route?
    @Published private(set) var routeDistance = 0.0
    @Published private(set) var nextManeuver: Maneuver?
    @Published private(set) var distanceToManeuver = 0.0
    @Published private(set) var isRouting = false
    @Published private(set) var activeState: String?
    @Published var message: String?

    let camera = CameraService()
    let motion = MotionService()
    let voice = VoiceGuide()
    private(set) var pack: RoadPack?
    private(set) var indexes: [SearchIndex] = []

    private var reckoner: DeadReckoner?
    private var destination: Coord?
    private var lastSample: MotionService.Sample?
    private var cameraSpeed: Double?
    private var cameraStill = false
    private var cameraTime = 0.0
    private var lastCameraFix = -10.0
    private var lastPublish = 0.0
    private var lastRouteRequest = 0.0
    private var lastSave = 0.0
    private var announcedEarly = Set<UUID>()
    private var announcedNow = Set<UUID>()
    private var signLimit: (mph: Int, odometer: Double, road: String)?
    private var pendingStreet: (name: String, time: Double)?
    private var warnedOverLimit = false
    private let defaults = UserDefaults.standard

    // MARK: settings (persisted)

    var mountHeight: Double {
        get { defaults.object(forKey: "mountHeight") as? Double ?? 1.2 }
        set { defaults.set(newValue, forKey: "mountHeight"); camera.mountHeight = newValue; objectWillChange.send() }
    }
    var roadBandBottom: Double {
        get { defaults.object(forKey: "roadBandBottom") as? Double ?? 0.15 }
        set { defaults.set(newValue, forKey: "roadBandBottom"); camera.roadBandBottom = newValue; objectWillChange.send() }
    }
    var voiceEnabled: Bool {
        get { defaults.object(forKey: "voiceEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "voiceEnabled"); voice.enabled = newValue; objectWillChange.send() }
    }
    var speedScale: Double { reckoner?.speedScale ?? (defaults.object(forKey: "speedScale") as? Double ?? 1.0) }

    func resetSpeedCalibration() {
        defaults.set(1.0, forKey: "speedScale")
        reckoner?.resetScale()
        objectWillChange.send()
    }

    // MARK: lifecycle

    init() {
        camera.mountHeight = mountHeight
        camera.roadBandBottom = roadBandBottom
        voice.enabled = voiceEnabled
        motion.onSample = { [weak self] in self?.handleMotion($0) }
        camera.onSpeed = { [weak self] speed, still in
            guard let self = self else { return }
            self.cameraSpeed = speed
            self.cameraStill = still
            self.cameraTime = CACurrentMediaTime()
            if speed != nil || still { self.lastCameraFix = self.cameraTime }
        }
        camera.onText = { [weak self] in self?.handleText($0) }
    }

    /// Open search indexes for the installed packs and restore the last known position.
    func load(installed: Set<String>) {
        indexes = installed.sorted().compactMap { SearchIndex(url: PackStore.fileURL($0, "search.sqlite"), state: $0) }
        if let active = activeState, !installed.contains(active) {
            pack = nil; reckoner = nil; activeState = nil; position = nil; route = nil; destination = nil
        }
        if reckoner == nil, let lat = defaults.object(forKey: "lastLat") as? Double,
           let lon = defaults.object(forKey: "lastLon") as? Double {
            _ = setPosition(Coord(lat: lat, lon: lon), announce: false)
        }
    }

    func startSensors() {
        UIApplication.shared.isIdleTimerDisabled = true
        motion.start()
        camera.start()
    }

    func stopSensors() {
        UIApplication.shared.isIdleTimerDisabled = false
        motion.stop()
        camera.stop()
        savePosition()
    }

    // MARK: position

    /// Place the car on the road nearest to `coord`. Returns false when no installed map covers it.
    @discardableResult
    func setPosition(_ coord: Coord, announce: Bool = true) -> Bool {
        let installed = Set(indexes.map(\.state))
        // prefer the active pack, then any installed pack that covers the point
        var candidates: [String] = []
        if let a = activeState { candidates.append(a) }
        candidates += installed.sorted().filter { $0 != activeState }
        for state in candidates {
            let opened: RoadPack? = state == activeState ? pack : openPack(state)
            guard let p = opened, p.contains(coord) else { continue }
            let declination = StateInfo.all.first { $0.id == state }?.declination ?? 0
            let hint = lastSample?.compassHeading.map { Geo.normalize($0 + declination) }
            let saved = defaults.object(forKey: "speedScale") as? Double ?? 1.0
            guard let r = DeadReckoner(pack: p, at: coord, headingHint: hint, savedScale: saved) else { continue }
            pack = p
            activeState = state
            reckoner = r
            signLimit = nil
            if destination != nil { requestRoute() } else { route = nil }
            publish(force: true)
            savePosition()
            if announce { message = "Position set on \(roadName.isEmpty ? "the nearest road" : roadName)." }
            return true
        }
        if announce { message = "No downloaded map has a road near that point." }
        return false
    }

    private func openPack(_ state: String) -> RoadPack? {
        try? RoadPack(url: PackStore.fileURL(state, "roads"))
    }

    func flipDirection() {
        reckoner?.flipDirection()
        if destination != nil { requestRoute() }
        publish(force: true)
    }

    private func savePosition() {
        guard let c = reckoner?.coordinate else { return }
        defaults.set(c.lat, forKey: "lastLat")
        defaults.set(c.lon, forKey: "lastLon")
        // only keep a calibration that was learned while the camera could see the road
        if cameraTracking, let s = reckoner?.speedScale { defaults.set(s, forKey: "speedScale") }
    }

    // MARK: routing

    func navigate(to coord: Coord) {
        guard reckoner != nil else {
            message = "Set your position on the map first."
            return
        }
        destination = coord
        announcedEarly.removeAll()
        announcedNow.removeAll()
        requestRoute(spoken: true)
    }

    func stopNavigation() {
        destination = nil
        route = nil
        nextManeuver = nil
        reckoner?.route = nil
        voice.stop()
    }

    private func requestRoute(spoken: Bool = false) {
        guard let pack = pack, let r = reckoner, let dest = destination, !isRouting else { return }
        guard pack.contains(dest) else {
            message = "That destination is outside the \(activeState ?? "current") map. Routes cannot cross state lines yet."
            destination = nil
            return
        }
        isRouting = true
        lastRouteRequest = CACurrentMediaTime()
        let start = r.position
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Router.route(pack: pack, from: start, to: dest)
            DispatchQueue.main.async {
                self.isRouting = false
                guard self.destination == dest, self.reckoner === r else { return }
                guard let found = result else {
                    self.message = "No drivable route found."
                    self.destination = nil
                    self.route = nil
                    return
                }
                self.route = found
                r.route = found
                self.announcedEarly.removeAll()
                self.announcedNow.removeAll()
                if spoken {
                    let miles = found.length / 1609.344
                    let minutes = Int((found.duration / 60).rounded())
                    self.voice.say(String(format: "Route ready. %.1f miles, about %d minutes.", miles, minutes))
                }
                self.publish(force: true)
            }
        }
    }

    // MARK: sensor handling

    private func handleMotion(_ s: MotionService.Sample) {
        lastSample = s
        camera.pitchDown = s.cameraPitchDown
        guard let r = reckoner else { return }
        let now = CACurrentMediaTime()
        let fresh = now - cameraTime < 0.4
        let cam = fresh ? cameraSpeed : nil
        let stationary = s.still && !((cam ?? 0) > 1.0) && (cameraStill || !fresh || cam == nil)
        r.update(MotionInput(dt: s.dt, forwardAccel: s.forwardAccel, yawRate: s.yawRate,
                             cameraSpeed: stationary ? nil : cam, stationary: stationary))
        let tracking = now - lastCameraFix < 2
        if tracking != cameraTracking { cameraTracking = tracking }

        if r.offRoute, destination != nil, !isRouting, now - lastRouteRequest > 4 {
            voice.say("Rerouting.")
            requestRoute()
        }
        publish(force: false)
        if now - lastSave > 15 { lastSave = now; savePosition() }
    }

    private func handleText(_ items: [SeenText]) {
        guard let r = reckoner, let pack = pack else { return }
        if let mph = SignParser.speedLimit(in: items) {
            signLimit = (mph, r.odometer, pack.displayName(r.edge))
        }
        let reach = max(150, r.uncertainty * 2)
        let ahead = r.crossStreetsAhead(within: reach)
        guard !ahead.isEmpty, let name = SignParser.matchStreet(in: items, candidates: ahead) else { return }
        let now = CACurrentMediaTime()
        // require the same street twice within a few seconds before trusting it
        if let p = pendingStreet, p.name == name, now - p.time < 4 {
            r.sawCrossStreet(named: name)
            pendingStreet = nil
        } else {
            pendingStreet = (name, now)
        }
    }

    // MARK: publishing + guidance

    private func publish(force: Bool) {
        guard let r = reckoner, let pack = pack else { return }
        let now = CACurrentMediaTime()
        guard force || now - lastPublish > 0.12 else { return }
        lastPublish = now
        let edge = r.edge
        position = r.coordinate
        heading = r.heading
        speedMph = r.speed * 2.236936
        uncertainty = r.uncertainty
        lost = r.lost
        let name = pack.displayName(edge)
        if name != roadName { roadName = name }

        // speed limit: a sign we read wins over map data until the road changes or 3 km pass
        if let s = signLimit, s.road != name || r.odometer - s.odometer > 3000 { signLimit = nil }
        let limit = signLimit?.mph ?? (edge.limitMph > 0 ? Int(edge.limitMph) : nil)
        if limit != limitMph { limitMph = limit }
        let over = limit.map { speedMph > Double($0) + 5 } ?? false
        if over != overLimit { overLimit = over }
        if over, !warnedOverLimit, let l = limit {
            warnedOverLimit = true
            voice.say("Speed limit \(l).")
        } else if !over, let l = limit, speedMph < Double(l) {
            warnedOverLimit = false
        }

        if route != nil, r.needsUTurn {
            if nextManeuver?.kind != .uTurn {
                nextManeuver = Maneuver(kind: .uTurn, roadName: "", distance: 0, coord: r.coordinate)
                distanceToManeuver = 0
                voice.say("Make a U-turn when it is safe.")
            }
            return
        }
        guard let route = route, let along = r.routeDistance else {
            if nextManeuver != nil, route == nil { nextManeuver = nil }
            return
        }
        routeDistance = along
        if route.length - along < 25 {
            voice.say("You have arrived.")
            stopNavigation()
            return
        }
        guard let next = route.maneuvers.first(where: { $0.distance > along + 3 }) else { return }
        let d = next.distance - along
        if nextManeuver?.id != next.id { nextManeuver = next }
        distanceToManeuver = d
        if next.kind != .arrive {
            if d < max(40, r.speed * 4), !announcedNow.contains(next.id) {
                announcedNow.insert(next.id)
                announcedEarly.insert(next.id)
                voice.say(next.text)
            } else if d < max(350, r.speed * 20), d > max(120, r.speed * 8), !announcedEarly.contains(next.id) {
                announcedEarly.insert(next.id)
                voice.say("In \(Self.spokenDistance(d)), \(next.text.prefix(1).lowercased() + next.text.dropFirst())")
            }
        }
    }

    static func spokenDistance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 900 { return "\(Int((feet / 50).rounded()) * 50) feet" }
        let miles = meters / 1609.344
        if miles < 0.95 { return String(format: "%.1f miles", miles).replacingOccurrences(of: "0.", with: "zero point ") }
        return String(format: "%.1f miles", miles)
    }

    static func displayDistance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 1000 { return "\(max(50, Int((feet / 50).rounded()) * 50)) ft" }
        return String(format: "%.1f mi", meters / 1609.344)
    }
}
