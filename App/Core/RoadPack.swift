import Foundation

/// One undirected road segment between two intersections.
struct RoadEdge {
    var a: UInt32
    var b: UInt32
    var pointStart: UInt32
    var nameOffset: UInt32
    var refOffset: UInt32
    var length: Float
    var pointCount: UInt16
    var roadClass: UInt8      // 0 motorway ... 6 service
    var flags: UInt8
    var limitMph: UInt8       // 0 = unknown
    var speedKph: UInt8       // routing speed

    var isOneWay: Bool { flags & 1 != 0 }
    var isLink: Bool { flags & 2 != 0 }
    var isRoundabout: Bool { flags & 4 != 0 }
}

/// An edge together with the direction it is driven in.
struct EdgeRef: Equatable, Hashable {
    var raw: UInt32
    init(raw: UInt32) { self.raw = raw }
    init(edge: UInt32, reversed: Bool) { raw = edge << 1 | (reversed ? 1 : 0) }
    var edge: UInt32 { raw >> 1 }
    var reversed: Bool { raw & 1 != 0 }
    var flipped: EdgeRef { EdgeRef(raw: raw ^ 1) }
}

struct EdgeSnap {
    var edge: UInt32
    var point: Coord
    var distance: Double          // metres from the query point
    var offset: Double            // metres from the edge's node `a` along its geometry
}

/// Memory-mapped reader for a `.roads` file written by tools/build_pack.py.
/// Layout is described in docs/PACK_FORMAT.md.
final class RoadPack {
    let url: URL
    private let data: NSData
    private let base: UnsafeRawPointer

    let minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    let nodeCount: Int, arcCount: Int, edgeCount: Int, pointCount: Int
    private let offNodes: Int, offArcs: Int, offEdges: Int, offPoints: Int, offStrings: Int
    private let stringBytes: Int

    private struct Grid {
        var lat0: Int32, lon0: Int32, cell: Int32
        var cols: Int, rows: Int
        var offStart: Int, offIds: Int
    }
    private let grids: [Grid]

    enum PackError: Error { case badFile }

    init(url: URL) throws {
        self.url = url
        let d = try NSData(contentsOf: url, options: .alwaysMapped)
        let b = d.bytes
        let length = d.length
        guard length > 128,
              b.loadUnaligned(fromByteOffset: 0, as: UInt32.self) == 0x4452_464F, // "OFRD"
              b.loadUnaligned(fromByteOffset: 4, as: UInt32.self) == 1 else { throw PackError.badFile }
        func i32(_ o: Int) -> Int32 { b.loadUnaligned(fromByteOffset: o, as: Int32.self) }
        func u32(_ o: Int) -> Int { Int(b.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
        var g = [Grid]()
        for k in 0..<3 {
            let o = u32(64 + 4 * k)
            guard o + 20 <= length else { throw PackError.badFile }
            let cols = u32(o + 12), rows = u32(o + 16)
            g.append(Grid(lat0: i32(o), lon0: i32(o + 4), cell: i32(o + 8), cols: cols, rows: rows,
                          offStart: o + 20, offIds: o + 20 + 4 * (cols * rows + 1)))
        }
        data = d
        base = b
        grids = g
        minLat = Double(i32(8)) / 1e7; minLon = Double(i32(12)) / 1e7
        maxLat = Double(i32(16)) / 1e7; maxLon = Double(i32(20)) / 1e7
        nodeCount = u32(24); arcCount = u32(28); edgeCount = u32(32); pointCount = u32(36)
        stringBytes = u32(40)
        offNodes = u32(44); offArcs = u32(48); offEdges = u32(52); offPoints = u32(56); offStrings = u32(60)
    }

    func contains(_ c: Coord) -> Bool {
        c.lat >= minLat && c.lat <= maxLat && c.lon >= minLon && c.lon <= maxLon
    }

    // MARK: raw accessors

    @inline(__always) private func u32(_ o: Int) -> UInt32 { base.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    @inline(__always) private func i32(_ o: Int) -> Int32 { base.loadUnaligned(fromByteOffset: o, as: Int32.self) }

    func nodeCoord(_ n: UInt32) -> Coord {
        let o = offNodes + Int(n) * 12
        return Coord(lat: Double(i32(o)) / 1e7, lon: Double(i32(o + 4)) / 1e7)
    }

    /// Range of arc indices leaving node `n`.
    func arcs(from n: UInt32) -> Range<Int> {
        let o = offNodes + Int(n) * 12 + 8
        return Int(u32(o))..<Int(u32(o + 12))
    }

    func arcTarget(_ k: Int) -> UInt32 { u32(offArcs + k * 8) }
    func arcEdge(_ k: Int) -> EdgeRef { EdgeRef(raw: u32(offArcs + k * 8 + 4)) }

    func edge(_ e: UInt32) -> RoadEdge {
        let o = offEdges + Int(e) * 32
        return RoadEdge(a: u32(o), b: u32(o + 4), pointStart: u32(o + 8), nameOffset: u32(o + 12),
                        refOffset: u32(o + 16),
                        length: base.loadUnaligned(fromByteOffset: o + 20, as: Float.self),
                        pointCount: base.loadUnaligned(fromByteOffset: o + 24, as: UInt16.self),
                        roadClass: base.load(fromByteOffset: o + 26, as: UInt8.self),
                        flags: base.load(fromByteOffset: o + 27, as: UInt8.self),
                        limitMph: base.load(fromByteOffset: o + 28, as: UInt8.self),
                        speedKph: base.load(fromByteOffset: o + 29, as: UInt8.self))
    }

    func point(_ i: Int) -> Coord {
        let o = offPoints + i * 8
        return Coord(lat: Double(i32(o)) / 1e7, lon: Double(i32(o + 4)) / 1e7)
    }

    func string(_ offset: UInt32) -> String {
        guard offset != 0, Int(offset) < stringBytes else { return "" }
        let p = (base + offStrings + Int(offset)).assumingMemoryBound(to: CChar.self)
        return String(cString: p)
    }

    /// Street name, falling back to the route number ("I 10").
    func displayName(_ e: RoadEdge) -> String {
        let n = string(e.nameOffset)
        return n.isEmpty ? string(e.refOffset) : n
    }

    /// Geometry of an edge in the given driving direction.
    func geometry(_ ref: EdgeRef) -> [Coord] {
        let e = edge(ref.edge)
        let s = Int(e.pointStart), n = Int(e.pointCount)
        var pts = [Coord]()
        pts.reserveCapacity(n)
        if ref.reversed {
            for i in stride(from: s + n - 1, through: s, by: -1) { pts.append(point(i)) }
        } else {
            for i in s..<(s + n) { pts.append(point(i)) }
        }
        return pts
    }

    /// Node at which driving along `ref` ends.
    func endNode(_ ref: EdgeRef) -> UInt32 { let e = edge(ref.edge); return ref.reversed ? e.a : e.b }
    func startNode(_ ref: EdgeRef) -> UInt32 { let e = edge(ref.edge); return ref.reversed ? e.b : e.a }

    /// Whether the edge may legally be driven in this direction.
    func isDrivable(_ ref: EdgeRef) -> Bool { !(ref.reversed && edge(ref.edge).isOneWay) }

    // MARK: spatial queries

    /// Level 0 = motorways/trunks, 1 = down to secondary roads, 2 = every road.
    func edges(level: Int, minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
               limit: Int = 60_000) -> [UInt32] {
        let g = grids[level]
        let cell = Double(g.cell)
        let x0 = max(0, Int(((minLon * 1e7 - Double(g.lon0)) / cell).rounded(.down)))
        let x1 = min(g.cols - 1, Int(((maxLon * 1e7 - Double(g.lon0)) / cell).rounded(.down)))
        let y0 = max(0, Int(((minLat * 1e7 - Double(g.lat0)) / cell).rounded(.down)))
        let y1 = min(g.rows - 1, Int(((maxLat * 1e7 - Double(g.lat0)) / cell).rounded(.down)))
        guard x0 <= x1, y0 <= y1 else { return [] }
        var seen = Set<UInt32>()
        var out = [UInt32]()
        for y in y0...y1 {
            for x in x0...x1 {
                let c = y * g.cols + x
                let s = Int(u32(g.offStart + c * 4)), e = Int(u32(g.offStart + (c + 1) * 4))
                for k in s..<e {
                    let id = u32(g.offIds + k * 4)
                    if seen.insert(id).inserted {
                        out.append(id)
                        if out.count >= limit { return out }
                    }
                }
            }
        }
        return out
    }

    /// Nearest road to a coordinate within `radius` metres.
    func snap(_ c: Coord, radius: Double = 300, maxClass: UInt8 = 6) -> EdgeSnap? {
        let dLat = radius / Geo.metersPerDegree
        let dLon = dLat / max(0.2, cos(c.lat * .pi / 180))
        let ids = edges(level: 2, minLat: c.lat - dLat, minLon: c.lon - dLon,
                        maxLat: c.lat + dLat, maxLon: c.lon + dLon)
        var best: EdgeSnap?
        for id in ids {
            let e = edge(id)
            if e.roadClass > maxClass { continue }
            let s = Int(e.pointStart)
            var along = 0.0
            var prev = point(s)
            for i in 1..<Int(e.pointCount) {
                let cur = point(s + i)
                let segLen = Geo.distance(prev, cur)
                let p = Geo.project(c, onto: prev, cur)
                if p.distance <= radius, p.distance < (best?.distance ?? .infinity) {
                    best = EdgeSnap(edge: id, point: p.point, distance: p.distance, offset: along + segLen * p.t)
                }
                along += segLen
                prev = cur
            }
        }
        return best
    }
}
