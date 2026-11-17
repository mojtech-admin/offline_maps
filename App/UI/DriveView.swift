import SwiftUI

struct DriveView: View {
    @ObservedObject var engine: NavigationEngine
    @ObservedObject var store: PackStore

    private enum Panel: String, Identifiable {
        case search, maps, settings
        var id: String { rawValue }
    }

    @State private var follow = true
    @State private var arMode = false
    @State private var metersPerPoint = 4.0
    @State private var pinchStart: Double?
    @State private var manualCenter = StateInfo.all[0].center
    @State private var dragStart: Coord?
    @State private var panel: Panel?
    @State private var cache = MapCache()

    private var following: Bool { follow && engine.position != nil }
    private var center: Coord { following ? (engine.position ?? manualCenter) : manualCenter }
    private var rotation: Double { following ? engine.heading : 0 }

    var body: some View {
        ZStack {
            if arMode {
                ARGuideView(engine: engine)
            } else {
                map
            }
            if !arMode && !following { crosshair }
            hud
        }
        .background(Color.black)
        .sheet(item: $panel) { which in
            switch which {
            case .search:
                SearchView(engine: engine,
                           onShow: { place in show(place.coord) },
                           onNavigate: { place in
                               engine.navigate(to: place.coord)
                               if engine.position != nil { follow = true } else { show(place.coord) }
                           },
                           onSetHere: { place in
                               if engine.setPosition(place.coord) { follow = true } else { show(place.coord) }
                           })
            case .maps: MapsView(store: store)
            case .settings: SettingsView(engine: engine)
            }
        }
        .onAppear {
            if engine.position == nil {
                let first = StateInfo.all.first { store.installed.contains($0.id) } ?? StateInfo.all[0]
                manualCenter = first.center
                metersPerPoint = 30
            }
        }
        .task(id: engine.message) {
            guard engine.message != nil else { return }
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { engine.message = nil }
        }
    }

    // MARK: map + gestures

    private var map: some View {
        MapCanvasView(pack: engine.pack ?? previewPack, cities: cityIndex, cache: cache, center: center,
                      rotation: rotation, metersPerPoint: metersPerPoint, route: engine.route,
                      routeDistance: engine.routeDistance, car: engine.position,
                      carHeading: engine.heading, uncertainty: engine.uncertainty)
            .ignoresSafeArea()
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = center
                            manualCenter = center
                            follow = false
                        }
                        guard let start = dragStart else { return }
                        // north-up while panning: drag right moves the map east-to-west under the finger
                        manualCenter = Geo.fromLocal(
                            LocalPoint(x: -Double(value.translation.width) * metersPerPoint,
                                       y: Double(value.translation.height) * metersPerPoint), origin: start)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil { pinchStart = metersPerPoint }
                        zoom(to: (pinchStart ?? metersPerPoint) / Double(value.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
    }

    /// Before a position is set there is no active pack; show the first installed one so the
    /// user can find where they are.
    private var previewPack: RoadPack? {
        engine.pack == nil ? PreviewPackHolder.shared.pack(for: store.installed, near: manualCenter) : nil
    }

    private var cityIndex: SearchIndex? {
        let state = engine.activeState ?? PreviewPackHolder.shared.state
        return engine.indexes.first { $0.state == state }
    }

    private func zoom(to value: Double) {
        metersPerPoint = max(0.6, min(3000, value))
    }

    private func show(_ coord: Coord) {
        arMode = false
        follow = false
        manualCenter = coord
        metersPerPoint = min(metersPerPoint, 6)
    }

    // MARK: overlays

    private var crosshair: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus").font(.system(size: 30, weight: .light)).foregroundColor(.white)
                .shadow(color: .black, radius: 2)
            HStack(spacing: 10) {
                Button {
                    if engine.setPosition(center) { follow = true; metersPerPoint = min(metersPerPoint, 5) }
                } label: { Label("I am here", systemImage: "location.fill") }
                Button {
                    engine.navigate(to: center)
                    if engine.position != nil { follow = true }
                } label: { Label("Drive here", systemImage: "arrow.triangle.turn.up.right.diamond.fill") }
                .disabled(engine.position == nil)
            }
            .buttonStyle(.borderedProminent)
            .font(.subheadline.weight(.semibold))
        }
        .offset(y: 34)      // keeps the plus sign itself on the map centre
    }

    private var hud: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    if let next = engine.nextManeuver, let route = engine.route {
                        maneuverBanner(next, route: route)
                    } else if engine.isRouting {
                        chip("Calculating route…", symbol: "hourglass", color: .blue)
                    } else if engine.position == nil {
                        chip("Drag the map until the + is where you are, then tap “I am here”",
                             symbol: "hand.draw", color: .blue)
                    }
                    if let message = engine.message { chip(message, symbol: "info.circle", color: .gray) }
                }
                Spacer()
                buttons
            }
            Spacer()
            HStack(alignment: .bottom) {
                speedPanel
                Spacer()
                statusPanel
                Spacer()
                VStack(spacing: 8) {
                    roundButton("plus") { zoom(to: metersPerPoint / 1.6) }
                    roundButton("minus") { zoom(to: metersPerPoint * 1.6) }
                }
                .opacity(arMode ? 0 : 1)
            }
        }
        .padding(12)
    }

    private func maneuverBanner(_ m: Maneuver, route: Route) -> some View {
        let remaining = max(0, route.length - engine.routeDistance)
        let minutes = Int((route.duration * remaining / max(1, route.length) / 60).rounded(.up))
        return HStack(spacing: 12) {
            Image(systemName: m.symbol).font(.system(size: 34, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(NavigationEngine.displayDistance(engine.distanceToManeuver)).font(.title2.bold()).monospacedDigit()
                Text(m.text).font(.subheadline).lineLimit(2)
                Text("\(NavigationEngine.displayDistance(remaining)) · \(minutes) min left")
                    .font(.caption).foregroundColor(.white.opacity(0.75))
            }
            Button { engine.stopNavigation() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2)
            }
            .accessibilityLabel("End route")
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(red: 0.05, green: 0.42, blue: 0.25), in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 380, alignment: .leading)
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            roundButton("magnifyingglass") { panel = .search }
            roundButton(arMode ? "map" : "camera.viewfinder") { arMode.toggle() }
            roundButton(following ? "location.fill" : "location") {
                if engine.position != nil { follow = true }
            }
            roundButton("arrow.up.arrow.down") { engine.flipDirection() }
            roundButton("square.and.arrow.down") { panel = .maps }
            roundButton("gearshape") { panel = .settings }
        }
    }

    private var speedPanel: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(spacing: 0) {
                Text("\(Int(engine.speedMph.rounded()))").font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("mph").font(.caption)
            }
            .foregroundColor(engine.overLimit ? .red : .white)
            .frame(width: 84, height: 84)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            if let limit = engine.limitMph {
                VStack(spacing: 0) {
                    Text("SPEED\nLIMIT").font(.system(size: 8, weight: .bold)).multilineTextAlignment(.center)
                    Text("\(limit)").font(.system(size: 24, weight: .bold))
                }
                .foregroundColor(.black)
                .frame(width: 48, height: 60)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black, lineWidth: 2).padding(2))
            }
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 6) {
            if engine.lost {
                chip("Position lost. Stop safely and set it again", symbol: "exclamationmark.triangle.fill", color: .red)
            }
            if !engine.roadName.isEmpty {
                Text(engine.roadName).font(.headline).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
            }
            if engine.position != nil {
                HStack(spacing: 6) {
                    Label(engine.cameraTracking ? "Camera speed" : "Sensors only",
                          systemImage: engine.cameraTracking ? "camera.fill" : "gyroscope")
                    Text("±\(NavigationEngine.displayDistance(engine.uncertainty))")
                }
                .font(.caption2).foregroundColor(engine.cameraTracking ? .green : .orange)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
            }
        }
    }

    private func chip(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.medium)).foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 420, alignment: .leading)
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.7), in: Circle())
                .foregroundColor(.white)
        }
    }
}

/// Opens installed road packs for browsing the map before a position has been set.
final class PreviewPackHolder {
    static let shared = PreviewPackHolder()
    private(set) var state: String?
    private var packs: [String: RoadPack] = [:]

    func pack(for installed: Set<String>, near coord: Coord) -> RoadPack? {
        packs = packs.filter { installed.contains($0.key) }
        for id in installed where packs[id] == nil {
            packs[id] = try? RoadPack(url: PackStore.fileURL(id, "roads"))
        }
        // prefer a pack that covers the point; break ties by the nearest main city
        let ranked = StateInfo.all.filter { packs[$0.id] != nil }.sorted {
            let a = packs[$0.id]!.contains(coord), b = packs[$1.id]!.contains(coord)
            if a != b { return a }
            return Geo.distance($0.center, coord) < Geo.distance($1.center, coord)
        }
        state = ranked.first?.id
        return state.flatMap { packs[$0] }
    }
}
