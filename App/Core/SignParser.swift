import Foundation

/// One piece of text the camera recognised, with its position in the frame (0...1, origin bottom-left).
struct SeenText {
    var text: String
    var x: Double
    var y: Double
    var height: Double
}

/// Turns raw OCR text into things the navigator can use. Pure logic, no camera code.
enum SignParser {
    private static let abbreviations: [String: String] = [
        "street": "st", "avenue": "ave", "av": "ave", "boulevard": "blvd", "road": "rd", "drive": "dr",
        "lane": "ln", "court": "ct", "place": "pl", "highway": "hwy", "parkway": "pkwy", "circle": "cir",
        "terrace": "ter", "trail": "trl", "square": "sq", "freeway": "fwy", "expressway": "expy",
        "north": "n", "south": "s", "east": "e", "west": "w",
        "northeast": "ne", "northwest": "nw", "southeast": "se", "southwest": "sw",
        "first": "1st", "second": "2nd", "third": "3rd", "fourth": "4th", "fifth": "5th",
        "saint": "st", "mount": "mt",
    ]

    /// "North Main Street" and "N MAIN ST" both become ["n", "main", "st"].
    static func tokens(_ s: String) -> [String] {
        let cleaned = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(cleaned).split(separator: " ").map { abbreviations[String($0)] ?? String($0) }
    }

    /// US speed limit signs read "SPEED LIMIT 65". Returns mph.
    static func speedLimit(in items: [SeenText]) -> Int? {
        let hasSpeed = items.contains { $0.text.uppercased().contains("SPEED") }
        let limitItems = items.filter { $0.text.uppercased().contains("LIMIT") }
        guard hasSpeed, !limitItems.isEmpty else { return nil }
        var best: (value: Int, distance: Double)?
        for item in items {
            for word in item.text.split(whereSeparator: { !$0.isNumber }) {
                guard let v = Int(word), v >= 15, v <= 85, v % 5 == 0 else { continue }
                // the number sits just below the word LIMIT on the same sign
                for l in limitItems {
                    let d = abs(item.x - l.x) + abs(item.y - l.y)
                    if d < 0.25, item.height >= l.height * 0.8, d < (best?.distance ?? .infinity) {
                        best = (v, d)
                    }
                }
            }
        }
        return best?.value
    }

    /// Which of the expected cross-street names (if any) appears in the recognised text.
    /// Street type words alone ("St", "Ave") never count as a match.
    static func matchStreet(in items: [SeenText], candidates: [String]) -> String? {
        let seen = items.map { tokens($0.text) }.filter { !$0.isEmpty }
        let generic = Set(abbreviations.values)
        var best: (name: String, weight: Int)?
        for name in candidates {
            let want = tokens(name)
            let core = want.filter { !generic.contains($0) }
            guard !core.isEmpty, core.joined().count >= 3 else { continue }
            for line in seen {
                let set = Set(line)
                if core.allSatisfy({ set.contains($0) }) {
                    let weight = core.joined().count + want.filter({ set.contains($0) }).count
                    if weight > (best?.weight ?? 0) { best = (name, weight) }
                }
            }
        }
        return best?.name
    }
}
