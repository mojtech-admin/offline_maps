import Foundation

/// One fused sensor sample handed to the dead reckoner.
struct MotionInput {
    var dt: Double
    var forwardAccel: Double        // m/s^2 along the car's direction of travel, gravity removed
    var yawRate: Double             // deg/s, positive when turning right
    var cameraSpeed: Double?        // m/s from optical flow, before calibration
    var stationary: Bool            // sensors say the car is not moving
}

/// Tracks the car on the road graph without GPS.
///
/// Speed comes from a small Kalman filter that integrates forward acceleration and corrects it
/// with the camera's optical-flow speed and stand-still detection. Heading comes from the gyroscope.
///
/// Position is a particle filter over the road network. Each particle ("walker") is one guess of
/// where the car is, with its own guess of how wrong the camera speed scale is. Walkers move along
/// roads only, and obey two rules that turn every corner into a position fix:
///  * a walker may not drive round a bend or through a junction that needs a turn until the
///    gyroscope has felt that turn; it waits there instead (it was running ahead of the car);
///  * a walker whose road no longer points the way the car is heading jumps to the nearest
///    stretch of road that does (it was running behind, or the car turned off).
/// Waiting and jumping cost a walker weight, so guesses with the wrong speed scale die out and
/// the scale calibrates itself after a few turns.
final class DeadReckoner {
    let pack: RoadPack

    private(set) var position: GraphPosition
    private(set) var heading: Double              // degrees clockwise from true north
    private(set) var uncertainty = 25.0           // spread of the walkers around the estimate, metres
    private(set) var lost = false
    private(set) var waitingForTurn = false       // the estimate reached a corner before the car did
    private(set) var offRoute = false
    private(set) var routeLeg = 0
    private(set) var odometer = 0.0               // metres since start
    private(set) var speedScale: Double           // learned camera speed correction
    var route: Route? { didSet { routeChanged() } }
    var trace: ((String) -> Void)?                // diagnostics hook, unused in the app

    /// Calibrated ground speed in m/s.
    var speed: Double { rawSpeed * speedScale }

    private struct Walker {
        var ref: EdgeRef
        var offset = 0.0
        var geom: [Coord] = []
        var cum: [Double] = [0]
        var scale = 1.0
        var logWeight = 0.0
        var held = 0.0               // metres "driven" while waiting at a corner
        var sinceFix = 0.0           // metres since this walker's position was last pinned down
        var offHeading = 0.0         // seconds its road has disagreed with the heading

        var length: Double { cum[cum.count - 1] }
    }

    private static let walkerCount = 80
    private var walkers: [Walker] = []
    private var estimate: Walker
    private var rawSpeed = 0.0                    // m/s in camera units (before scale)
    private var speedVar = 4.0
    private var accelBias = 0.0
    private var timeSinceCamera = 0.0
    private var offRouteTime = 0.0
    private var routeRefs = Set<EdgeRef>()
    private var rng = SystemRandomNumberGenerator()

    init?(pack: RoadPack, at coord: Coord, headingHint: Double?, savedScale: Double = 1.0) {
        guard let snap = pack.snap(coord, radius: 500) else { return nil }
        self.pack = pack
        speedScale = savedScale
        position = GraphPosition(ref: EdgeRef(edge: snap.edge, reversed: false), offset: snap.offset)
        estimate = Walker(ref: position.ref)
        heading = 0
        place(on: snap, headingHint: headingHint)
    }

    // MARK: derived state

    var edge: RoadEdge { pack.edge(position.ref.edge) }
    var coordinate: Coord { coord(of: estimate) }
    var roadBearing: Double { bearing(of: estimate) }

    /// Distance travelled along the active route, if the estimate is on it.
    var routeDistance: Double? {
        guard let r = route, !offRoute, routeLeg < r.legs.count, r.legs[routeLeg] == position.ref else { return nil }
        return max(0, r.legStart[routeLeg] + position.offset)
    }

    /// The route starts by turning around on the road we are on.
    var needsUTurn: Bool {
        guard let r = route, let first = r.legs.first else { return false }
        return routeLeg == 0 && first == position.ref.flipped
    }

    // MARK: manual corrections

    /// Re-place the car at a coordinate (user tapped "I am here").
    @discardableResult
    func setPosition(_ coord: Coord, headingHint: Double?) -> Bool {
        guard let snap = pack.snap(coord, radius: 500) else { return false }
        place(on: snap, headingHint: headingHint)
        return true
    }

    /// The car is on the right road but pointing the other way.
    func flipDirection() {
        let flipped = position.ref.flipped
        guard pack.isDrivable(flipped) else { return }
        seedWalkers(ref: flipped, offset: estimate.length - position.offset)
        heading = roadBearing
    }

    func resetScale() {
        speedScale = 1.0
        seedWalkers(ref: position.ref, offset: position.offset)
    }

    private func place(on snap: EdgeSnap, headingHint: Double?) {
        let e = pack.edge(snap.edge)
        var ref = EdgeRef(edge: snap.edge, reversed: false)
        var offset = snap.offset
        if !e.isOneWay, let hint = headingHint {
            var probe = Walker(ref: ref)
            load(&probe, ref: ref, offset: offset)
            if abs(Geo.angleDiff(hint, bearing(of: probe))) > 90 {
                ref = ref.flipped
                offset = Double(e.length) - snap.offset
            }
        }
        rawSpeed = 0
        speedVar = 4
        seedWalkers(ref: ref, offset: offset)
        heading = roadBearing
    }

    /// Start every walker near one spot, with a spread of speed-scale guesses.
    private func seedWalkers(ref: EdgeRef, offset: Double) {
        var template = Walker(ref: ref)
        load(&template, ref: ref, offset: offset)
        // an uncalibrated camera can easily be 15% off; a learned scale is trusted more
        let sigma = abs(speedScale - 1) < 1e-6 ? 0.12 : 0.05
        var seeded: [Walker] = []
        for i in 0..<Self.walkerCount {
            var w = template
            if i > 0 {
                w.offset = max(0, min(w.length, offset + gauss() * 8))
                w.scale = max(0.4, min(2.5, speedScale * (1 + gauss() * sigma)))
            } else {
                w.scale = speedScale
            }
            seeded.append(w)
        }
        walkers = seeded
        lost = false
        offRouteTime = 0
        refreshEstimate()
        routeChanged()
    }

    // MARK: main update

    func update(_ m: MotionInput) {
        let dt = max(0, min(0.5, m.dt))
        heading = Geo.normalize(heading + m.yawRate * dt)

        // --- speed filter (camera units) ---
        timeSinceCamera += dt
        if m.stationary {
            accelBias += 0.05 * (m.forwardAccel - accelBias)
            fuseSpeed(0, variance: 0.01)
        } else {
            rawSpeed += (m.forwardAccel - accelBias) * dt / speedScale
            speedVar += 0.4 * dt
        }
        if let z = m.cameraSpeed {
            let sigma = 0.8 + 0.15 * z
            if abs(z - rawSpeed) < 4 * (speedVar + sigma * sigma).squareRoot() + 2 || speedVar > 9 {
                fuseSpeed(z, variance: sigma * sigma)
            }
            timeSinceCamera = 0
        } else if !m.stationary, dt > 0, timeSinceCamera > 2 {
            // No camera reading for a while: the accelerometer alone drifts within seconds, so
            // lean gently (time constant ~10 s) on the typical speed of the road we are on.
            let typical = Double(max(5, edge.speedKph)) / 3.6 / speedScale
            let sigma = 0.35 * typical
            fuseSpeed(typical, variance: sigma * sigma * 10 / dt)
        }
        rawSpeed = max(0, min(70, rawSpeed))

        // --- move every walker ---
        let base = rawSpeed * dt
        let blind = timeSinceCamera > 2
        odometer += base * speedScale
        let moving = speed > 1.5
        for i in walkers.indices {
            // without the camera the distance itself is a guess, so let walkers disagree more
            let ds = base * walkers[i].scale * (blind ? max(0, 1 + gauss() * 0.3) : 1)
            if ds > 0 {
                let heldBefore = walkers[i].held
                advance(&walkers[i], ds)
                walkers[i].sinceFix += ds
                walkers[i].logWeight -= 0.03 * max(0, walkers[i].held - heldBefore)
            }
            let diff = abs(Geo.angleDiff(heading, bearing(of: walkers[i])))
            if diff > 20 { walkers[i].logWeight -= 2 * dt * ((diff - 20) / 30) * ((diff - 20) / 30) }
            if diff < 25 {
                walkers[i].offHeading = min(0, walkers[i].offHeading + dt)
            } else if moving {
                walkers[i].offHeading += dt
                if walkers[i].offHeading > 0.6 {
                    if jumpToMatchingRoad(&walkers[i]) {
                        walkers[i].offHeading = 0
                    } else if walkers[i].offHeading > 4 {
                        walkers[i].offHeading = 3.4      // keep trying a few times a second
                    }
                }
            }
        }
        resampleIfNeeded()
        refreshEstimate()

        // --- keep the gyro heading from drifting: pull it slowly toward the matched road.
        // Slow (20 s) and only for small differences, so a gentle fork is not mistaken for drift.
        let diff = Geo.angleDiff(heading, roadBearing)
        if abs(diff) < 15 { heading = Geo.normalize(heading - diff * min(1, 0.05 * dt)) }
        updateRouteProgress(dt)
    }

    private func fuseSpeed(_ z: Double, variance r: Double) {
        let k = speedVar / (speedVar + r)
        rawSpeed += k * (z - rawSpeed)
        speedVar *= (1 - k)
    }

    // MARK: walker motion

    /// Move a walker along the road graph, stopping at any corner the gyroscope has not felt yet.
    private func advance(_ w: inout Walker, _ ds: Double) {
        var remaining = ds
        var hops = 0
        while remaining > 0, hops < 20 {
            hops += 1
            let target = w.offset + remaining

            // a bend inside this road segment
            var j = segment(of: w, at: w.offset) + 1
            var block: Double?
            while j < w.geom.count - 1, w.cum[j] <= target {
                if abs(Geo.angleDiff(Geo.bearing(w.geom[j], w.geom[j + 1]), heading)) > 50 { block = w.cum[j]; break }
                j += 1
            }
            if let b = block {
                w.held += target - b
                w.offset = b
                return
            }
            if target < w.length {
                releaseHold(&w)
                w.offset = target
                return
            }

            // the junction at the end of this segment
            let over = target - w.length
            guard let next = chooseArc(at: pack.endNode(w.ref), from: w.ref) else {
                w.held += over
                w.offset = w.length
                return
            }
            let wasHolding = w.held > 15
            releaseHold(&w)
            load(&w, ref: next, offset: 0)
            remaining = wasHolding ? 0 : over
        }
    }

    private func releaseHold(_ w: inout Walker) {
        if w.held > 15 { w.sinceFix = 0 }       // the turn came exactly here: position is pinned
        w.held = 0
    }

    /// The way out of a junction that matches the current heading, if any does (within 50 degrees).
    private func chooseArc(at node: UInt32, from current: EdgeRef) -> EdgeRef? {
        let back = current.flipped
        var best: EdgeRef?
        var bestScore = Double.infinity
        for k in pack.arcs(from: node) {
            let ref = pack.arcEdge(k)
            if ref == back { continue }
            let e = pack.edge(ref.edge)
            let s = Int(e.pointStart), n = Int(e.pointCount)
            guard n > 1 else { continue }
            let p0 = pack.point(ref.reversed ? s + n - 1 : s)
            let p1 = pack.point(ref.reversed ? s + n - 2 : s + 1)
            let angle = abs(Geo.angleDiff(Geo.bearing(p0, p1), heading))
            if angle > 50 { continue }
            var score = angle
            if routeRefs.contains(ref) { score -= 25 }
            if e.roadClass == 6 { score += 10 }
            if score < bestScore { bestScore = score; best = ref }
        }
        return best
    }

    /// The walker's road no longer points the way the car is heading. Move it to the nearest
    /// stretch of road that does: the street the car turned onto, a bend further along, or the
    /// same road in the other direction after a U-turn. The further the jump, the more it costs.
    private func jumpToMatchingRoad(_ w: inout Walker) -> Bool {
        let here = coord(of: w)
        let radius = max(45, min(500, 30 + 0.25 * w.sinceFix))
        let dLat = radius / Geo.metersPerDegree
        let dLon = dLat / max(0.2, cos(here.lat * .pi / 180))
        let ids = pack.edges(level: 2, minLat: here.lat - dLat, minLon: here.lon - dLon,
                             maxLat: here.lat + dLat, maxLon: here.lon + dLon, limit: 3000)
        var best: (ref: EdgeRef, offset: Double, distance: Double)?
        var bestScore = Double.infinity
        for id in ids {
            let e = pack.edge(id)
            let s = Int(e.pointStart), n = Int(e.pointCount)
            guard n > 1 else { continue }
            var along = 0.0
            var prev = pack.point(s)
            for i in 1..<n {
                let cur = pack.point(s + i)
                let segLen = Geo.distance(prev, cur)
                defer { along += segLen; prev = cur }
                if segLen <= 0 { continue }
                let forward = Geo.bearing(prev, cur)
                for reversed in [false, true] {
                    if reversed && e.isOneWay { continue }
                    let angle = abs(Geo.angleDiff(reversed ? forward + 180 : forward, heading))
                    if angle > 22 { continue }
                    let p = Geo.project(here, onto: prev, cur)
                    if p.distance > radius { continue }
                    let ref = EdgeRef(edge: id, reversed: reversed)
                    var score = angle + 25 * p.distance / radius
                    if routeRefs.contains(ref) { score -= 10 }
                    if score < bestScore {
                        bestScore = score
                        let fromA = along + segLen * p.t
                        best = (ref, reversed ? Double(e.length) - fromA : fromA, p.distance)
                    }
                }
            }
        }
        guard let hit = best else { return false }
        let sigma = 20 + 0.1 * w.sinceFix
        w.logWeight -= min(12, 0.5 * (hit.distance / sigma) * (hit.distance / sigma))
        load(&w, ref: hit.ref, offset: hit.offset + min(15, speed * 0.3))
        w.held = 0
        w.sinceFix = 0
        return true
    }

    // MARK: particle bookkeeping

    private func resampleIfNeeded() {
        let top = walkers.map(\.logWeight).max() ?? 0
        var weights = walkers.map { exp($0.logWeight - top) }
        let sum = weights.reduce(0, +)
        guard sum > 0 else { return }
        for i in weights.indices { weights[i] /= sum }
        let effective = 1 / weights.reduce(0) { $0 + $1 * $1 }
        for i in walkers.indices { walkers[i].logWeight -= top }
        guard effective < Double(walkers.count) * 0.5 else { return }
        // systematic resampling; copies get a slightly different scale so the cloud keeps exploring
        let n = walkers.count
        var next: [Walker] = []
        next.reserveCapacity(n)
        let step = 1.0 / Double(n)
        var u = Double.random(in: 0..<step, using: &rng)
        var cumulative = weights[0]
        var i = 0
        var taken = Set<Int>()
        for _ in 0..<n {
            while u > cumulative, i < n - 1 { i += 1; cumulative += weights[i] }
            var w = walkers[i]
            w.logWeight = 0
            if !taken.insert(i).inserted {
                w.scale = max(0.4, min(2.5, w.scale * (1 + gauss() * 0.012)))
                w.offset = max(0, min(w.length, w.offset + gauss() * 2))
            }
            next.append(w)
            u += step
        }
        walkers = next
    }

    /// The reported position: the road carrying the most weight, at the walkers' mean spot on it.
    private func refreshEstimate() {
        var perRef: [EdgeRef: Double] = [:]
        var total = 0.0, scaleSum = 0.0
        for w in walkers {
            let weight = exp(w.logWeight)
            perRef[w.ref, default: 0] += weight
            total += weight
            scaleSum += weight * w.scale
        }
        guard total > 0, let bestRef = perRef.max(by: { $0.value < $1.value })?.key else { return }
        var offsetSum = 0.0, refWeight = 0.0, heldSum = 0.0, offSum = 0.0
        var sample: Walker?
        for w in walkers where w.ref == bestRef {
            let weight = exp(w.logWeight)
            offsetSum += weight * w.offset
            heldSum += weight * w.held
            offSum += weight * w.offHeading
            refWeight += weight
            if sample == nil { sample = w }
        }
        guard var e = sample, refWeight > 0 else { return }
        e.offset = max(0, min(e.length, offsetSum / refWeight))
        estimate = e
        position = GraphPosition(ref: e.ref, offset: e.offset)
        speedScale = scaleSum / total
        waitingForTurn = heldSum / refWeight > 15
        lost = offSum / refWeight > 3 || heldSum / refWeight > 1500

        let here = coordinate
        var spread = 0.0
        for w in walkers {
            let d = Geo.distance(here, coord(of: w))
            spread += exp(w.logWeight) * d * d
        }
        uncertainty = max(10, (spread / total).squareRoot())
    }

    // MARK: route progress

    private func routeChanged() {
        routeRefs = Set(route?.legs ?? [])
        routeLeg = 0
        offRoute = false
        offRouteTime = 0
        updateRouteProgress(0)
    }

    private func updateRouteProgress(_ dt: Double) {
        guard let r = route else { return }
        let ref = position.ref
        if routeLeg < r.legs.count, r.legs[routeLeg] == ref {
            offRouteTime = 0
        } else if let i = r.legIndex(of: ref, from: max(0, routeLeg - 1)) ?? r.legIndex(of: ref, from: 0) {
            routeLeg = i
            offRouteTime = 0
        } else if routeLeg == 0, r.legs.first == ref.flipped {
            offRouteTime = 0                    // waiting for the driver to turn around
        } else {
            offRouteTime += dt
        }
        offRoute = offRouteTime > 2.5
    }

    // MARK: sign anchoring

    /// Names of cross streets at junctions within reach ahead of the car, for the sign reader.
    func crossStreetsAhead(within reach: Double) -> [String] {
        var out: [String] = []
        let own = pack.displayName(edge)
        var ref = position.ref
        var dist = estimate.length - position.offset
        var hops = 0
        while dist < reach, hops < 12 {
            hops += 1
            let node = pack.endNode(ref)
            let g0 = pack.geometry(ref)
            let inBearing = Geo.bearing(g0[g0.count - 2], g0[g0.count - 1])
            var straight: EdgeRef?
            var straightScore = 60.0
            for k in pack.arcs(from: node) {
                let next = pack.arcEdge(k)
                if next == ref.flipped { continue }
                let name = pack.displayName(pack.edge(next.edge))
                if !name.isEmpty, name != own, !out.contains(name) { out.append(name) }
                let g = pack.geometry(next)
                let score = routeRefs.contains(next) ? -1 : abs(Geo.angleDiff(Geo.bearing(g[0], g[1]), inBearing))
                if score < straightScore { straightScore = score; straight = next }
            }
            guard let next = straight else { break }
            ref = next
            dist += Double(pack.edge(next.edge).length)
        }
        return out
    }

    /// A street-name sign for this cross street was read, so the car is close to a junction with
    /// it. Walkers that are nowhere near such a junction lose weight.
    func sawCrossStreet(named name: String) {
        for i in walkers.indices {
            let w = walkers[i]
            let nearEnd = w.length - w.offset < 80 && nodeTouches(pack.endNode(w.ref), street: name)
            let nearStart = w.offset < 25 && nodeTouches(pack.startNode(w.ref), street: name)
            if !nearEnd && !nearStart { walkers[i].logWeight -= 2.5 }
        }
        resampleIfNeeded()
        refreshEstimate()
    }

    private func nodeTouches(_ node: UInt32, street: String) -> Bool {
        for k in pack.arcs(from: node) where pack.displayName(pack.edge(pack.arcEdge(k).edge)) == street { return true }
        return false
    }

    // MARK: geometry helpers

    private func load(_ w: inout Walker, ref: EdgeRef, offset: Double) {
        w.ref = ref
        w.geom = pack.geometry(ref)
        var cum = [0.0]
        cum.reserveCapacity(w.geom.count)
        for i in 1..<max(1, w.geom.count) { cum.append(cum[i - 1] + Geo.distance(w.geom[i - 1], w.geom[i])) }
        w.cum = cum
        w.offset = max(0, min(w.length, offset))
    }

    private func segment(of w: Walker, at o: Double) -> Int {
        var i = 0
        while i + 2 < w.cum.count, w.cum[i + 1] < o { i += 1 }
        return i
    }

    private func coord(of w: Walker) -> Coord {
        guard w.geom.count > 1 else { return w.geom.first ?? Coord(lat: 0, lon: 0) }
        let i = segment(of: w, at: w.offset)
        let seg = w.cum[i + 1] - w.cum[i]
        return Geo.interpolate(w.geom[i], w.geom[i + 1], seg > 0 ? max(0, min(1, (w.offset - w.cum[i]) / seg)) : 0)
    }

    private func bearing(of w: Walker) -> Double {
        guard w.geom.count > 1 else { return heading }
        let i = segment(of: w, at: w.offset)
        return Geo.bearing(w.geom[i], w.geom[i + 1])
    }

    private func gauss() -> Double {
        let u1 = Double.random(in: 1e-12..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
