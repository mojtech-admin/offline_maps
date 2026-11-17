import Foundation

/// A WGS84 coordinate in degrees.
struct Coord: Equatable {
    var lat: Double
    var lon: Double
}

/// A point in a local flat frame, metres east (x) and north (y) of an origin.
struct LocalPoint {
    var x: Double
    var y: Double
}

enum Geo {
    static let earthRadius = 6_371_008.8
    static let metersPerDegree = 111_194.93

    static func distance(_ a: Coord, _ b: Coord) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dLat = p2 - p1
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(p1) * cos(p2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from a to b, degrees clockwise from north, 0..<360.
    static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let p1 = a.lat * .pi / 180, p2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dLon)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    static func normalize(_ deg: Double) -> Double {
        let d = deg.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// Signed smallest difference a - b in degrees, -180...180.
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// Equirectangular projection around `origin`; accurate to well under 1% within ~100 km.
    static func toLocal(_ c: Coord, origin: Coord) -> LocalPoint {
        LocalPoint(x: (c.lon - origin.lon) * metersPerDegree * cos(origin.lat * .pi / 180),
                   y: (c.lat - origin.lat) * metersPerDegree)
    }

    static func fromLocal(_ p: LocalPoint, origin: Coord) -> Coord {
        Coord(lat: origin.lat + p.y / metersPerDegree,
              lon: origin.lon + p.x / (metersPerDegree * cos(origin.lat * .pi / 180)))
    }

    static func interpolate(_ a: Coord, _ b: Coord, _ t: Double) -> Coord {
        Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
    }

    /// Closest point to `p` on segment a-b. Returns the point, its parameter 0...1 and distance in metres.
    static func project(_ p: Coord, onto a: Coord, _ b: Coord) -> (point: Coord, t: Double, distance: Double) {
        let pa = toLocal(a, origin: p), pb = toLocal(b, origin: p)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? -(pa.x * dx + pa.y * dy) / len2 : 0
        t = max(0, min(1, t))
        let qx = pa.x + dx * t, qy = pa.y + dy * t
        return (interpolate(a, b, t), t, (qx * qx + qy * qy).squareRoot())
    }
}
