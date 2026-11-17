import Foundation

struct Maneuver: Identifiable {
    enum Kind: Equatable {
        case depart, continueOn, slightLeft, left, sharpLeft, slightRight, right, sharpRight
        case uTurn, rampLeft, rampRight, merge, roundabout(exit: Int), arrive
    }
    let id = UUID()
    var kind: Kind
    var roadName: String
    var distance: Double        // metres from the route start to this manoeuvre
    var coord: Coord

    var text: String {
        let onto = roadName.isEmpty ? "" : " onto \(roadName)"
        switch kind {
        case .depart: return roadName.isEmpty ? "Start driving" : "Head out on \(roadName)"
        case .continueOn: return "Continue\(onto)"
        case .slightLeft: return "Keep left\(onto)"
        case .left: return "Turn left\(onto)"
        case .sharpLeft: return "Sharp left\(onto)"
        case .slightRight: return "Keep right\(onto)"
        case .right: return "Turn right\(onto)"
        case .sharpRight: return "Sharp right\(onto)"
        case .uTurn: return "Make a U-turn"
        case .rampLeft: return "Take the ramp on the left" + (roadName.isEmpty ? "" : " toward \(roadName)")
        case .rampRight: return "Take the ramp on the right" + (roadName.isEmpty ? "" : " toward \(roadName)")
        case .merge: return "Merge\(onto)"
        case .roundabout(let exit): return "At the roundabout, take exit \(exit)\(onto)"
        case .arrive: return "You have arrived"
        }
    }

    var symbol: String {
        switch kind {
        case .depart, .continueOn: return "arrow.up"
        case .slightLeft, .rampLeft: return "arrow.up.left"
        case .left, .sharpLeft: return "arrow.turn.up.left"
        case .slightRight, .rampRight: return "arrow.up.right"
        case .right, .sharpRight: return "arrow.turn.up.right"
        case .uTurn: return "arrow.uturn.down"
        case .merge: return "arrow.merge"
        case .roundabout: return "arrow.triangle.2.circlepath"
        case .arrive: return "mappin.and.ellipse"
        }
    }
}

struct Route {
    var legs: [EdgeRef]
    var legStart: [Double]       // route distance at which each leg's edge begins (may be negative for leg 0)
    var polyline: [Coord]
    var cumulative: [Double]     // distance along polyline at each vertex
    var maneuvers: [Maneuver]
    var length: Double
    var duration: Double         // seconds
    var destination: Coord

    /// Coordinate at a distance along the route.
    func coord(at d: Double) -> Coord {
        guard polyline.count > 1 else { return polyline.first ?? destination }
        if d <= 0 { return polyline[0] }
        if d >= length { return polyline[polyline.count - 1] }
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= d { lo = mid } else { hi = mid }
        }
        let seg = cumulative[hi] - cumulative[lo]
        return Geo.interpolate(polyline[lo], polyline[hi], seg > 0 ? (d - cumulative[lo]) / seg : 0)
    }

    /// Index of the leg that drives `ref`, searching from `from`.
    func legIndex(of ref: EdgeRef, from: Int = 0) -> Int? {
        guard from < legs.count else { return nil }
        return legs[from...].firstIndex(of: ref)
    }
}

/// A position on the road graph: an edge driven in a direction, and metres travelled along it.
struct GraphPosition {
    var ref: EdgeRef
    var offset: Double
}

private struct MinHeap {
    private var items: [(Float, UInt32)] = []
    var isEmpty: Bool { items.isEmpty }
    var top: Float { items.first?.0 ?? .infinity }

    mutating func push(_ key: Float, _ value: UInt32) {
        items.append((key, value))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].0 <= items[i].0 { break }
            items.swapAt(parent, i)
            i = parent
        }
    }

    mutating func pop() -> (Float, UInt32) {
        let result = items[0]
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var m = i
                if l < items.count && items[l].0 < items[m].0 { m = l }
                if r < items.count && items[r].0 < items[m].0 { m = r }
                if m == i { break }
                items.swapAt(m, i)
                i = m
            }
        }
        return result
    }
}

enum Router {
    static let uTurnPenalty: Float = 60        // seconds
    static let maxSpeed = 36.2                 // m/s, keeps the A* heuristic admissible

    /// Fastest route from a graph position to the road nearest `destination`.
    /// Runs synchronously; call it off the main thread for long trips.
    static func route(pack: RoadPack, from start: GraphPosition, to destination: Coord) -> Route? {
        guard let goal = pack.snap(destination, radius: 2000) else { return nil }
        let goalEdge = pack.edge(goal.edge)
        let goalSpeed = Float(max(5, goalEdge.speedKph)) / 3.6
        let startEdge = pack.edge(start.ref.edge)
        let startSpeed = Float(max(5, startEdge.speedKph)) / 3.6
        let startLen = Double(startEdge.length)
        let startOffset = max(0, min(startLen, start.offset))

        // goalTail[node] = seconds from that end of the goal edge to the destination
        var goalTail: [UInt32: Float] = [goalEdge.a: Float(goal.offset) / goalSpeed]
        if !goalEdge.isOneWay {
            let viaB = Float(Double(goalEdge.length) - goal.offset) / goalSpeed
            goalTail[goalEdge.b] = min(goalTail[goalEdge.b] ?? .infinity, viaB)
            if goalEdge.a == goalEdge.b { goalTail[goalEdge.a] = min(goalTail[goalEdge.a]!, viaB) }
        }

        var cost = [Float](repeating: .infinity, count: pack.nodeCount)
        var prev = [Int32](repeating: -1, count: pack.nodeCount)   // arc index, -2 fwd seed, -3 flipped seed
        var heap = MinHeap()
        func h(_ n: UInt32) -> Float { Float(Geo.distance(pack.nodeCoord(n), goal.point) / maxSpeed) }

        let fwdNode = pack.endNode(start.ref)
        cost[Int(fwdNode)] = Float(startLen - startOffset) / startSpeed
        prev[Int(fwdNode)] = -2
        heap.push(cost[Int(fwdNode)] + h(fwdNode), fwdNode)
        if !startEdge.isOneWay {
            let backNode = pack.startNode(start.ref)
            let c = Float(startOffset) / startSpeed + uTurnPenalty
            if c < cost[Int(backNode)] {
                cost[Int(backNode)] = c
                prev[Int(backNode)] = -3
                heap.push(c + h(backNode), backNode)
            }
        }

        var best = Float.infinity
        var bestNode: UInt32?
        var direct = false
        // destination lies ahead on the edge we are already driving
        if start.ref.edge == goal.edge {
            let goalAlong = start.ref.reversed ? startLen - goal.offset : goal.offset
            if goalAlong >= startOffset {
                best = Float(goalAlong - startOffset) / startSpeed
                direct = true
            }
        }

        while !heap.isEmpty, heap.top < best {
            let (f, n) = heap.pop()
            let c = cost[Int(n)]
            if f > c + h(n) + 0.01 { continue }          // stale entry
            if let tail = goalTail[n], c + tail < best {
                best = c + tail
                bestNode = n
                direct = false
            }
            for k in pack.arcs(from: n) {
                let ref = pack.arcEdge(k)
                let e = pack.edge(ref.edge)
                let t = pack.arcTarget(k)
                let nc = c + e.length / (Float(max(5, e.speedKph)) / 3.6)
                if nc < cost[Int(t)] {
                    cost[Int(t)] = nc
                    prev[Int(t)] = Int32(k)
                    heap.push(nc + h(t), t)
                }
            }
        }
        guard best.isFinite else { return nil }

        // rebuild the leg list
        var legs: [EdgeRef] = []
        var firstOffset = startOffset
        var lastOffset: Double
        if direct {
            legs = [start.ref]
            lastOffset = start.ref.reversed ? startLen - goal.offset : goal.offset
        } else {
            guard let end = bestNode else { return nil }
            let viaA = end == goalEdge.a &&
                (goalEdge.isOneWay || goalEdge.a == goalEdge.b ||
                 Float(goal.offset) / goalSpeed <= goalTail[end]! + 0.001)
            let goalRef = EdgeRef(edge: goal.edge, reversed: !viaA)
            lastOffset = viaA ? goal.offset : Double(goalEdge.length) - goal.offset
            var rev: [EdgeRef] = [goalRef]
            var n = end
            var guardCount = 0
            while true {
                let p = prev[Int(n)]
                if p == -2 { rev.append(start.ref); break }
                if p == -3 {
                    rev.append(start.ref.flipped)
                    firstOffset = startLen - startOffset
                    break
                }
                if p < 0 { return nil }
                let ref = pack.arcEdge(Int(p))
                rev.append(ref)
                n = pack.startNode(ref)
                guardCount += 1
                if guardCount > pack.nodeCount { return nil }
            }
            legs = rev.reversed()
        }
        return assemble(pack: pack, legs: legs, firstOffset: firstOffset, lastOffset: lastOffset,
                        duration: Double(best), destination: goal.point)
    }

    private static func assemble(pack: RoadPack, legs: [EdgeRef], firstOffset: Double, lastOffset: Double,
                                 duration: Double, destination: Coord) -> Route {
        var polyline: [Coord] = []
        var cumulative: [Double] = []
        var legStart: [Double] = []
        var total = 0.0

        func append(_ c: Coord) {
            if let last = polyline.last {
                let d = Geo.distance(last, c)
                if d < 0.01 { return }
                total += d
            }
            polyline.append(c)
            cumulative.append(total)
        }

        for (i, ref) in legs.enumerated() {
            let pts = pack.geometry(ref)
            let from = i == 0 ? firstOffset : 0
            let to = i == legs.count - 1 ? lastOffset : Double.infinity
            legStart.append(total - (i == 0 ? firstOffset : 0))
            var along = 0.0
            for j in 1..<pts.count {
                let seg = Geo.distance(pts[j - 1], pts[j])
                let a = along, b = along + seg
                along = b
                if b < from || a > to || seg <= 0 { continue }
                let t0 = max(0, (from - a) / seg), t1 = min(1, (to - a) / seg)
                append(Geo.interpolate(pts[j - 1], pts[j], t0))
                append(Geo.interpolate(pts[j - 1], pts[j], t1))
            }
        }
        if polyline.isEmpty { polyline = [destination]; cumulative = [0] }

        var maneuvers: [Maneuver] = []
        let firstName = pack.displayName(pack.edge(legs[0].edge))
        maneuvers.append(Maneuver(kind: .depart, roadName: firstName, distance: 0, coord: polyline[0]))
        var i = 0
        while i + 1 < legs.count {
            let inRef = legs[i], outRef = legs[i + 1]
            let e1 = pack.edge(inRef.edge), e2 = pack.edge(outRef.edge)
            let node = pack.endNode(inRef)
            let at = max(0, legStart[i + 1])
            let coord = pack.nodeCoord(node)
            if e2.isRoundabout && !e1.isRoundabout {
                // count exits until the route leaves the roundabout
                var exit = 0
                var j = i + 1
                while j < legs.count, pack.edge(legs[j].edge).isRoundabout {
                    let n = pack.endNode(legs[j])
                    for k in pack.arcs(from: n) where !pack.edge(pack.arcEdge(k).edge).isRoundabout { exit += 1; break }
                    j += 1
                }
                let name = j < legs.count ? pack.displayName(pack.edge(legs[j].edge)) : ""
                maneuvers.append(Maneuver(kind: .roundabout(exit: max(1, exit)), roadName: name, distance: at, coord: coord))
                i = max(i + 1, j - 1)
                continue
            }
            let gin = pack.geometry(inRef), gout = pack.geometry(outRef)
            let turn = Geo.angleDiff(Geo.bearing(gout[0], gout[1]),
                                     Geo.bearing(gin[gin.count - 2], gin[gin.count - 1]))
            var choices = 0
            for k in pack.arcs(from: node) where pack.arcEdge(k) != inRef.flipped { choices += 1 }
            let name1 = pack.displayName(e1), name2 = pack.displayName(e2)
            let mag = abs(turn)
            var kind: Maneuver.Kind?
            if inRef.edge == outRef.edge {
                kind = .uTurn
            } else if e2.isLink && !e1.isLink && choices > 1 {
                kind = turn < 0 ? .rampLeft : .rampRight
            } else if e1.isLink && !e2.isLink {
                kind = .merge
            } else if choices > 1 || mag >= 50 {
                if mag < 20 {
                    if !name1.isEmpty && !name2.isEmpty && name1 != name2 && !e1.isLink { kind = .continueOn }
                } else if mag < 50 {
                    kind = turn < 0 ? .slightLeft : .slightRight
                } else if mag < 130 {
                    kind = turn < 0 ? .left : .right
                } else if mag < 170 {
                    kind = turn < 0 ? .sharpLeft : .sharpRight
                } else {
                    kind = .uTurn
                }
            }
            if let kind = kind {
                maneuvers.append(Maneuver(kind: kind, roadName: name2, distance: at, coord: coord))
            }
            i += 1
        }
        maneuvers.append(Maneuver(kind: .arrive, roadName: "", distance: total, coord: polyline[polyline.count - 1]))
        return Route(legs: legs, legStart: legStart, polyline: polyline, cumulative: cumulative,
                     maneuvers: maneuvers, length: total, duration: duration, destination: destination)
    }
}
