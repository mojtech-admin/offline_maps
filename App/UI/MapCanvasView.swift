import SwiftUI

/// Road geometry for the area around the viewport, pre-projected to local metres so that each
/// frame only has to apply one affine transform.
final class MapCache {
    private(set) var origin = Coord(lat: 0, lon: 0)
    private(set) var radius = 0.0
    private(set) var level = -1
    private(set) var paths: [Path] = Array(repeating: Path(), count: 7)     // one per road class
    private(set) var roadLabels: [(name: String, at: CGPoint, roadClass: UInt8)] = []
    private(set) var cityLabels: [(name: String, at: CGPoint, rank: Bool)] = []
    private var packURL: URL?

    static func level(for metersPerPoint: Double) -> Int {
        metersPerPoint > 40 ? 0 : (metersPerPoint > 6 ? 1 : 2)
    }

    func local(_ c: Coord) -> CGPoint {
        let p = Geo.toLocal(c, origin: origin)
        return CGPoint(x: p.x, y: p.y)
    }

    /// Rebuild when the viewport leaves the cached area or the detail level changes.
    func prepare(pack: RoadPack, cities: SearchIndex?, center: Coord, visibleRadius: Double, metersPerPoint: Double) {
        let wanted = Self.level(for: metersPerPoint)
        let drift = Geo.distance(center, origin)
        if packURL == pack.url, wanted == level, drift + visibleRadius <= radius, radius < visibleRadius * 6 { return }
        packURL = pack.url
        level = wanted
        origin = center
        radius = visibleRadius * 1.8

        let dLat = radius / Geo.metersPerDegree
        let dLon = dLat / max(0.2, cos(center.lat * .pi / 180))
        let ids = pack.edges(level: level, minLat: center.lat - dLat, minLon: center.lon - dLon,
                             maxLat: center.lat + dLat, maxLon: center.lon + dLon)
        var built = Array(repeating: Path(), count: 7)
        var labels: [(name: String, at: CGPoint, roadClass: UInt8)] = []
        var named = Set<String>()
        for id in ids {
            let e = pack.edge(id)
            let cls = Int(min(6, e.roadClass))
            let s = Int(e.pointStart), n = Int(e.pointCount)
            guard n > 1 else { continue }
            built[cls].move(to: local(pack.point(s)))
            for i in 1..<n { built[cls].addLine(to: local(pack.point(s + i))) }
            if labels.count < 400, e.length > 60 {
                let name = cls <= 1 && e.refOffset != 0 ? pack.string(e.refOffset) : pack.displayName(e)
                if !name.isEmpty, named.insert(name).inserted {
                    labels.append((name, local(pack.point(s + n / 2)), e.roadClass))
                }
            }
        }
        paths = built
        roadLabels = labels.sorted { $0.roadClass < $1.roadClass }
        let maxRank = metersPerPoint > 800 ? 0 : (metersPerPoint > 150 ? 1 : (metersPerPoint > 30 ? 2 : 4))
        cityLabels = (cities?.cities(minLat: center.lat - dLat, minLon: center.lon - dLon,
                                     maxLat: center.lat + dLat, maxLon: center.lon + dLon,
                                     maxRank: maxRank) ?? [])
            .map { ($0.name, local($0.coord), $0.detail == "city" || $0.detail == "town") }
    }
}

/// The moving map: roads, labels, the planned route and the car.
struct MapCanvasView: View {
    let pack: RoadPack?
    let cities: SearchIndex?
    let cache: MapCache
    let center: Coord
    let rotation: Double            // compass bearing shown at the top of the screen
    let metersPerPoint: Double
    let route: Route?
    let routeDistance: Double
    let car: Coord?
    let carHeading: Double
    let uncertainty: Double

    private static let background = Color(red: 0.09, green: 0.10, blue: 0.12)
    private static let roadColors: [Color] = [
        Color(red: 0.96, green: 0.62, blue: 0.30), Color(red: 0.93, green: 0.72, blue: 0.38),
        Color(red: 0.88, green: 0.80, blue: 0.52), Color(white: 0.74), Color(white: 0.60),
        Color(white: 0.42), Color(white: 0.30),
    ]
    private static let roadWidths: [CGFloat] = [5, 4.5, 4, 3.2, 2.6, 2, 1.2]

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.background))
            guard let pack = pack else { return }
            let visible = Double(hypot(size.width, size.height)) / 2 * metersPerPoint
            cache.prepare(pack: pack, cities: cities, center: center, visibleRadius: visible,
                          metersPerPoint: metersPerPoint)
            let t = transform(size: size)
            let zoomScale: CGFloat = metersPerPoint < 3 ? 1.8 : (metersPerPoint < 10 ? 1.2 : (metersPerPoint < 60 ? 0.8 : 0.55))

            // minor roads first so major roads paint over them
            for cls in stride(from: 6, through: 0, by: -1) {
                let path = cache.paths[cls]
                if path.isEmpty { continue }
                context.stroke(path.applying(t), with: .color(Self.roadColors[cls]),
                               style: StrokeStyle(lineWidth: max(0.8, Self.roadWidths[cls] * zoomScale),
                                                  lineCap: .round, lineJoin: .round))
            }

            if let route = route, route.polyline.count > 1 {
                var line = Path()
                line.move(to: cache.local(route.polyline[0]))
                for c in route.polyline.dropFirst() { line.addLine(to: cache.local(c)) }
                context.stroke(line.applying(t), with: .color(Color(red: 0.25, green: 0.55, blue: 1.0)),
                               style: StrokeStyle(lineWidth: max(4, 6 * zoomScale), lineCap: .round, lineJoin: .round))
                let end = cache.local(route.destination).applying(t)
                context.fill(Path(ellipseIn: CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16)), with: .color(.red))
                context.stroke(Path(ellipseIn: CGRect(x: end.x - 8, y: end.y - 8, width: 16, height: 16)),
                               with: .color(.white), lineWidth: 2)
            }

            drawLabels(context: context, size: size, transform: t)

            if let car = car {
                let p = cache.local(car).applying(t)
                let r = CGFloat(min(400, max(0, uncertainty / metersPerPoint)))
                if r > 14 {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                                 with: .color(Color.blue.opacity(0.12)))
                }
                let angle = (carHeading - rotation) * .pi / 180
                var arrow = Path()
                arrow.move(to: CGPoint(x: 0, y: -16))
                arrow.addLine(to: CGPoint(x: 11, y: 12))
                arrow.addLine(to: CGPoint(x: 0, y: 6))
                arrow.addLine(to: CGPoint(x: -11, y: 12))
                arrow.closeSubpath()
                let placed = arrow.applying(CGAffineTransform(translationX: p.x, y: p.y).rotated(by: CGFloat(angle)))
                context.fill(placed, with: .color(Color(red: 0.2, green: 0.6, blue: 1.0)))
                context.stroke(placed, with: .color(.white), lineWidth: 2)
            }
        }
    }

    private func transform(size: CGSize) -> CGAffineTransform {
        let theta = rotation * .pi / 180
        let c0 = Geo.toLocal(center, origin: cache.origin)
        let cosT = cos(theta) / metersPerPoint, sinT = sin(theta) / metersPerPoint
        return CGAffineTransform(a: CGFloat(cosT), b: CGFloat(-sinT), c: CGFloat(-sinT), d: CGFloat(-cosT),
                                 tx: size.width / 2 - CGFloat(c0.x * cosT - c0.y * sinT),
                                 ty: size.height / 2 + CGFloat(c0.x * sinT + c0.y * cosT))
    }

    private func drawLabels(context: GraphicsContext, size: CGSize, transform t: CGAffineTransform) {
        var used: [CGRect] = []
        func place(_ text: Text, at p: CGPoint, width: CGFloat) -> Bool {
            let box = CGRect(x: p.x - width / 2, y: p.y - 9, width: width, height: 18)
            guard box.minX > 0, box.maxX < size.width, box.minY > 0, box.maxY < size.height,
                  !used.contains(where: { $0.intersects(box) }) else { return false }
            used.append(box)
            context.draw(text, at: p)
            return true
        }
        for city in cache.cityLabels {
            let text = Text(city.name).font(.system(size: city.rank ? 15 : 12, weight: .semibold))
                .foregroundColor(.white)
            _ = place(text, at: city.at.applying(t), width: CGFloat(city.name.count) * 8 + 10)
        }
        guard metersPerPoint < 25 else { return }
        var count = 0
        for label in cache.roadLabels where count < 28 {
            if label.roadClass > 4 && metersPerPoint > 3 { continue }
            let text = Text(label.name).font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.92))
            if place(text, at: label.at.applying(t), width: CGFloat(label.name.count) * 6.5 + 8) { count += 1 }
        }
    }
}
