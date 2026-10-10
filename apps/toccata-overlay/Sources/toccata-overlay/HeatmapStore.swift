import Foundation
import SQLite3

struct HeatmapData {
    let counts: [UInt16: Int]
    let maxCount: Int
    let available: Bool

    static let unavailable = HeatmapData(counts: [:], maxCount: 0, available: false)
}

final class HeatmapStore {
    func load() -> HeatmapData {
        var db: OpaquePointer?
        guard sqlite3_open_v2(ToccataPaths.databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return .unavailable
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT keycode, COUNT(*) FROM key_events WHERE kind = 0 GROUP BY keycode"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .unavailable
        }
        defer { sqlite3_finalize(stmt) }

        var counts: [UInt16: Int] = [:]
        var maxCount = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let code = sqlite3_column_int64(stmt, 0)
            let n = Int(sqlite3_column_int64(stmt, 1))
            guard code >= 0, code <= Int64(UInt16.max) else { continue }
            counts[UInt16(code)] = n
            maxCount = max(maxCount, n)
        }
        return HeatmapData(counts: counts, maxCount: maxCount, available: true)
    }
}
