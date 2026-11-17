import Foundation
import SQLite3

struct Place: Identifiable, Hashable {
    var id: String
    var kind: String        // city, street, address, poi
    var name: String
    var detail: String
    var lat: Double
    var lon: Double
    var state: String

    var coord: Coord { Coord(lat: lat, lon: lon) }
    var symbol: String {
        switch kind {
        case "city": return "building.2"
        case "street": return "road.lanes"
        case "address": return "house"
        default: return "mappin"
        }
    }
}

/// Offline place search over one state's `.search.sqlite` (SQLite FTS5, built by tools/build_pack.py).
final class SearchIndex {
    let state: String
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL, state: String) {
        self.state = state
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    /// Prefix search: every word typed must start a word in the name or its town.
    func search(_ text: String, limit: Int = 25) -> [Place] {
        let words = text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return [] }
        let match = words.map { "\"\($0)\"*" }.joined(separator: " ")
        let sql = """
            SELECT p.id, p.kind, p.name, p.detail, p.lat, p.lon
            FROM place_fts f JOIN place p ON p.id = f.rowid
            WHERE place_fts MATCH ?1 ORDER BY p.rank, bm25(place_fts) LIMIT ?2
            """
        return query(sql) { stmt in
            sqlite3_bind_text(stmt, 1, match, -1, self.transient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        }
    }

    /// Town and city labels inside a bounding box, most important first.
    func cities(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
                maxRank: Int, limit: Int = 40) -> [Place] {
        let sql = """
            SELECT id, kind, name, detail, lat, lon FROM place
            WHERE kind = 'city' AND rank <= ?1 AND lat BETWEEN ?2 AND ?3 AND lon BETWEEN ?4 AND ?5
            ORDER BY rank LIMIT ?6
            """
        return query(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(maxRank))
            sqlite3_bind_double(stmt, 2, minLat)
            sqlite3_bind_double(stmt, 3, maxLat)
            sqlite3_bind_double(stmt, 4, minLon)
            sqlite3_bind_double(stmt, 5, maxLon)
            sqlite3_bind_int(stmt, 6, Int32(limit))
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void) -> [Place] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var out: [Place] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            out.append(Place(id: "\(state)-\(sqlite3_column_int64(stmt, 0))", kind: text(1), name: text(2),
                             detail: text(3), lat: sqlite3_column_double(stmt, 4),
                             lon: sqlite3_column_double(stmt, 5), state: state))
        }
        return out
    }
}
