// Command-line check of the navigation core (no iOS frameworks needed), for Linux or macOS:
//   swiftc -O App/Core/*.swift tools/coretest/main.swift -o coretest && ./coretest PACK.roads
// It routes through a chain of waypoints, then replays that drive through the dead reckoner with
// imperfect sensors (camera speed off by a fixed factor plus noise, biased accelerometer and
// gyroscope) and reports how far the estimate strays from the truth.
import Foundation

let args = CommandLine.arguments
guard args.count > 1, let pack = try? RoadPack(url: URL(fileURLWithPath: args[1])) else {
    print("usage: coretest PACK.roads [waypoints]"); exit(2)
}
let legsWanted = args.count > 2 ? Int(args[2]) ?? 6 : 6
print("pack: \(pack.nodeCount) nodes, \(pack.edgeCount) edges")

// --- truth: a drive through pseudo-random waypoints inside the pack ---
var seed: UInt64 = 42
func rnd() -> Double {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Double(seed >> 11) / Double(1 << 53)
}
func randomCoord() -> Coord {
    Coord(lat: pack.minLat + rnd() * (pack.maxLat - pack.minLat), lon: pack.minLon + rnd() * (pack.maxLon - pack.minLon))
}
var truth: [Coord] = []
var cum: [Double] = []
var first: Route?
var position: GraphPosition?
for _ in 0..<legsWanted * 4 where truth.isEmpty || cum.last! < Double(legsWanted) * 1500 {
    if position == nil {
        guard let s = pack.snap(randomCoord(), radius: 50_000) else { continue }
        position = GraphPosition(ref: EdgeRef(edge: s.edge, reversed: false), offset: s.offset)
    }
    guard let r = Router.route(pack: pack, from: position!, to: randomCoord()), r.length > 200 else { continue }
    if first == nil { first = r }
    for c in r.polyline {
        if let last = truth.last {
            let d = Geo.distance(last, c)
            if d < 0.01 { continue }
            cum.append(cum.last! + d)
        } else {
            cum.append(0)
        }
        truth.append(c)
    }
    // continue from where this leg ended, in the direction of arrival
    let lastRef = r.legs[r.legs.count - 1]
    guard let s = pack.snap(r.polyline[r.polyline.count - 1], radius: 30) else { break }
    let len = Double(pack.edge(lastRef.edge).length)
    position = GraphPosition(ref: lastRef, offset: lastRef.reversed ? len - s.offset : s.offset)
}
guard let firstRoute = first, truth.count > 2 else { print("FAIL: could not build a test drive"); exit(1) }
let total = cum[cum.count - 1]
print(String(format: "test drive: %.1f km. First leg: %.2f km, %.1f min", total / 1000, firstRoute.length / 1000, firstRoute.duration / 60))
for m in firstRoute.maneuvers.prefix(12) { print(String(format: "  %7.0f m  %@", m.distance, m.text)) }

func at(_ d: Double) -> Coord {
    if d <= 0 { return truth[0] }
    if d >= total { return truth[truth.count - 1] }
    var lo = 0, hi = cum.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if cum[mid] <= d { lo = mid } else { hi = mid } }
    return Geo.interpolate(truth[lo], truth[hi], (d - cum[lo]) / max(1e-9, cum[hi] - cum[lo]))
}
func heading(at s: Double) -> Double { Geo.bearing(at(max(0, s - 4)), at(min(total, s + 4))) }

struct Result { var median = 0.0, p90 = 0.0, worst = 0.0, end = 0.0, scale = 0.0, lostShare = 0.0 }

func simulate(cameraScale: Double?, gyroBias: Double) -> Result {
    guard let r = DeadReckoner(pack: pack, at: truth[0], headingHint: heading(at: 1)) else { return Result() }
    let dt = 1.0 / 30
    var s = 0.0, v = 0.0, t = 0.0
    var lastHeading = heading(at: 0)
    var errors: [Double] = []
    var lost = 0
    while s < total - 30, t < 4 * 3600 {
        let turning = abs(Geo.angleDiff(heading(at: s + 25), heading(at: s))) > 30
        let target = turning ? 5.0 : 14.0
        let accel = max(-3, min(2, (target - v) * 0.8))
        v = max(0, v + accel * dt)
        s += v * dt
        let h = heading(at: s)
        let yaw = Geo.angleDiff(h, lastHeading) / dt
        lastHeading = h
        let cam = cameraScale.map { v * $0 * (1 + (rnd() - 0.5) * 0.1) }
        // the camera loses the road now and then
        let camOK = v > 0.5 && rnd() > 0.15
        r.update(MotionInput(dt: dt, forwardAccel: accel + 0.15 + (rnd() - 0.5) * 0.6,
                             yawRate: yaw + gyroBias + (rnd() - 0.5),
                             cameraSpeed: camOK ? cam : nil, stationary: v < 0.05))
        if t > 2 { errors.append(Geo.distance(r.coordinate, at(s))) }
        if r.lost { lost += 1 }
        t += dt
    }
    errors.sort()
    guard !errors.isEmpty else { return Result() }
    return Result(median: errors[errors.count / 2], p90: errors[errors.count * 9 / 10], worst: errors[errors.count - 1],
                  end: Geo.distance(r.coordinate, at(s)), scale: r.speedScale, lostShare: Double(lost) / Double(errors.count))
}

var failed = false
let cases: [(String, Double?, Double, Double)] = [
    ("camera exact          ", 1.0, 0.1, 60),   // limits assume a drive with turns
    ("camera reads 15% high ", 1.15, 0.1, 150),
    ("camera reads 12% low  ", 0.88, -0.1, 150),
    ("no camera at all      ", nil, 0.1, .infinity),
]
for (label, cam, bias, limit) in cases {
    let r = simulate(cameraScale: cam, gyroBias: bias)
    let ok = r.median < limit
    if !ok { failed = true }
    print(String(format: "%@ error median %4.0f m, 90%% %4.0f m, worst %5.0f m, at end %4.0f m | scale %.2f | flagged lost %2.0f%% of the time  %@",
                 label, r.median, r.p90, r.worst, r.end, r.scale, r.lostShare * 100, ok ? "ok" : "FAIL"))
}

// --- sign parsing ---
let signs = [SeenText(text: "SPEED", x: 0.5, y: 0.62, height: 0.03), SeenText(text: "LIMIT", x: 0.5, y: 0.58, height: 0.03),
             SeenText(text: "45", x: 0.5, y: 0.52, height: 0.06), SeenText(text: "N MAIN ST", x: 0.2, y: 0.8, height: 0.03)]
let limitOK = SignParser.speedLimit(in: signs) == 45
let streetOK = SignParser.matchStreet(in: signs, candidates: ["Oak Avenue", "North Main Street"]) == "North Main Street"
    && SignParser.matchStreet(in: signs, candidates: ["Oak Street"]) == nil
print("sign parser: limit \(limitOK ? "ok" : "FAIL"), street \(streetOK ? "ok" : "FAIL")")
exit(failed || !limitOK || !streetOK ? 1 : 0)
