import Foundation
import SQLite3

/// Disposable derived data. The collector remains the only writer of the source
/// database. Completed days are materialized on demand; only new source rows are
/// inspected for invalidation. Cross-day releases have their own small index so
/// reading an old day never requires reading every event between that day and now.
final class DailyStatisticsCache {
    struct Diagnostics {
        var sourceRowsRead = 0
        var daysComputed = 0
        var dayCacheHits = 0
    }

    private static let registryLock = NSLock()
    private static var registry: [String: DailyStatisticsCache] = [:]

    static func shared(for url: URL) -> DailyStatisticsCache {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = url.standardizedFileURL.path
        if let existing = registry[key] { return existing }
        // Test/portable databases must not accumulate open connections forever.
        if registry.count >= 8 { registry.removeAll() }
        let cache = DailyStatisticsCache(sourceURL: url)
        registry[key] = cache
        return cache
    }

    private let sourceURL: URL
    private let cacheURL: URL
    private let lock = NSLock()
    private var source: Database?
    private var sourceIdentity: String?
    private var lastDataVersion: Int64?
    private var counters = Diagnostics()
    var diagnostics: Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    init(sourceURL: URL, cacheURL: URL? = nil) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.cacheURL = cacheURL ?? sourceURL.deletingPathExtension().appendingPathExtension("statistics-cache.sqlite")
    }

    func activity(range: ActivityRange, now: Date, calendar: Calendar, policy: ActivityPolicy,
                  liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false) throws -> ActivitySnapshot {
        try access(now: now, calendar: calendar, policy: policy) { db, cache, hasApp in
            let interval = range.interval(now: now, calendar: calendar)
            let nowMs = ActivityCalculator.milliseconds(now)
            let liveStart = liveConnected ? liveEvents.filter { $0.timestampMs <= nowMs }.map {
                min($0.timestampMs, ActivityCalculator.activitySpan(for: $0, policy: policy)?.startMs ?? $0.timestampMs)
            }.min() : nil
            var result = ActivitySnapshot()
            for day in days(in: interval, calendar: calendar) {
                // Reconstruct overlapping live days rather than adding durations
                // to a cached total: persisted and live intervals can overlap.
                let affectedByLive = liveStart.map { $0 < ActivityCalculator.milliseconds(day.end) } ?? false
                let summary = try summary(day: day, now: now, calendar: calendar, policy: policy,
                    db: db, cache: cache, hasApp: hasApp,
                    liveEvents: affectedByLive ? liveEvents : [], liveConnected: affectedByLive && liveConnected)
                result.days.append(summary.day)
                result.activeMs += summary.day.activeMs
                result.fnMs += summary.day.fnMs
                result.keyCount += summary.day.keyCount
                for (key, count) in summary.keyCounts { result.keyCounts[key, default: 0] += count }
            }
            return result
        }
    }

    func topApps(interval: DateInterval, limit: Int, now: Date, calendar: Calendar,
                 policy: ActivityPolicy) throws -> [AppRank] {
        guard limit > 0, interval.start < now else { return [] }
        return try access(now: now, calendar: calendar, policy: policy) { db, cache, hasApp in
            var totals: [String: (usage: Int64, keys: Int64)] = [:]
            for day in days(in: interval, calendar: calendar) where day.start < now {
                let value = try summary(day: day, now: now, calendar: calendar, policy: policy,
                    db: db, cache: cache, hasApp: hasApp)
                // Keep every app in each day; limit only after combining days.
                for app in value.apps {
                    let previous = totals[app.app] ?? (0, 0)
                    totals[app.app] = (previous.usage + app.usageMs, previous.keys + app.keyCount)
                }
            }
            let ranks: [AppRank] = totals.map { entry in
                AppRank(app: entry.key, usageMs: entry.value.usage, keyCount: entry.value.keys)
            }
            let ordered = ranks.sorted { lhs, rhs in
                lhs.usageMs == rhs.usageMs ? lhs.app < rhs.app : lhs.usageMs > rhs.usageMs
            }
            return Array(ordered.prefix(limit))
        }
    }

    func dailyCounts(calendar: Calendar, policy: ActivityPolicy) throws -> [String: Int] {
        try access(now: Date(), calendar: calendar, policy: policy) { _, cache, _ in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // Match SQLite date(...,'localtime') and the heatmap's POSIX keys,
            // even when the user's preferred system calendar is not Gregorian.
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return Dictionary(uniqueKeysWithValues: try cache.query("SELECT day_start, count FROM key_counts") {
                (formatter.string(from: date(columnInt64($0, 0))), columnInt($0, 1))
            })
        }
    }

    private struct SourceEvent: Codable, Equatable, Hashable {
        let rowID: Int64
        let timestamp: Int64
        let keycode: Int
        let kind: Int
        let hold: Int64?
        let app: String?
        var activity: ActivityKeyEvent {
            ActivityKeyEvent(timestampMs: timestamp, keycode: keycode, kind: kind, holdMs: hold)
        }
        static func read(_ stmt: OpaquePointer) -> SourceEvent {
            SourceEvent(rowID: columnInt64(stmt, 0), timestamp: columnInt64(stmt, 1),
                keycode: columnInt(stmt, 2), kind: columnInt(stmt, 3),
                hold: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : columnInt64(stmt, 4),
                app: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : columnText(stmt, 5))
        }
    }

    private struct State: Codable {
        let signature: String
        var cursor: Int64 = 0
        var lastRow: SourceEvent?
        var firstRow: SourceEvent?
        var lastNow: Int64 = 0
    }

    private struct Summary: Codable {
        let day: ActivityDay
        let keyCounts: [Int: Int]
        let apps: [AppRank]
    }

    private func access<T>(now: Date, calendar: Calendar, policy: ActivityPolicy,
                           work: (Database, DerivedDatabase, Bool) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard cacheURL.resolvingSymlinksInPath() != sourceURL.resolvingSymlinksInPath() else {
            throw CacheError.invalidPayload
        }
        do {
            return try accessOnce(now: now, calendar: calendar, policy: policy, work: work)
        } catch {
            guard CacheError.isCorruption(error) else { throw error }
            // All handles/transactions from the failed request have unwound.
            // Only derived data is disposable; never remove the source or reset
            // a healthy cache on permission, lock, or storage-space failures.
            for suffix in ["", "-wal", "-shm"] {
                let path = cacheURL.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
            return try accessOnce(now: now, calendar: calendar, policy: policy, work: work)
        }
    }

    private func accessOnce<T>(now: Date, calendar: Calendar, policy: ActivityPolicy,
                               work: (Database, DerivedDatabase, Bool) throws -> T) throws -> T {
        let identity = try fileIdentity()
        if identity != sourceIdentity {
            source = try Database(url: sourceURL)
            sourceIdentity = identity
            lastDataVersion = nil
        }
        let db = source!
        let cache = try DerivedDatabase(url: cacheURL)
        // Cache changes and watermark advancement are one transaction, and every
        // source read in this request observes the same committed WAL snapshot.
        let completed: (T, Int64) = try db.readSnapshot {
            try cache.transaction {
                let hasApp = try db.query("PRAGMA table_info(key_events)") { columnText($0, 1) }.contains("app")
                let columns = "rowid, ts_ms, keycode, kind, hold_ms, \(hasApp ? "app" : "NULL")"
                let schema = try db.query("PRAGMA schema_version") { columnInt64($0, 0) }.first ?? 0
                let dataVersion = try db.query("PRAGMA data_version") { columnInt64($0, 0) }.first ?? 0
                let first = try db.query("SELECT \(columns) FROM key_events ORDER BY rowid LIMIT 1", row: SourceEvent.read).first
                let last = try db.query("SELECT \(columns) FROM key_events ORDER BY rowid DESC LIMIT 1", row: SourceEvent.read).first
                let high = last?.rowID ?? 0
                let signature = "v1|\(sourceURL.path)|\(identity)|\(schema)|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(policy.activityWindowMs)"
                let nowMs = ActivityCalculator.milliseconds(now)
                var state: State? = try cache.decoded("SELECT json FROM metadata WHERE id=1")
                if let old = state {
                    let anchor = old.cursor > 0 ? try db.query("SELECT \(columns) FROM key_events WHERE rowid=?", params: [old.cursor], row: SourceEvent.read).first : nil
                    let changedWithoutAppend = high == old.cursor && (lastDataVersion.map { $0 != dataVersion } ?? false)
                    if old.signature != signature || high < old.cursor || old.firstRow != first || old.lastRow != anchor
                        || changedWithoutAppend {
                        state = nil
                    }
                }
                if state == nil {
                    try cache.run("DELETE FROM daily_summaries")
                    try cache.run("DELETE FROM crossing_releases")
                    try cache.run("DELETE FROM key_counts")
                    state = State(signature: signature)
                }
                var current = state!
                let oldCursor = current.cursor
                while current.cursor < high {
                    let rows = try db.query("SELECT \(columns) FROM key_events WHERE rowid>? AND rowid<=? ORDER BY rowid LIMIT 4096",
                        params: [current.cursor, high], row: SourceEvent.read)
                    guard let end = rows.last else { break }
                    counters.sourceRowsRead += rows.count
                    try ingest(rows, calendar: calendar, policy: policy, cache: cache)
                    current.cursor = end.rowID
                }
                // Rows with future timestamps may have been indexed previously.
                // When time reaches them their holds can change a completed day.
                // Independently queued UI requests can arrive a few milliseconds
                // out of order. Invalidate only events crossing the time boundary,
                // never discard the whole cache merely because now moved back.
                if current.lastNow > 0, nowMs != current.lastNow, oldCursor > 0 {
                    let newlyEffective = try db.query("SELECT \(columns) FROM key_events WHERE ts_ms>? AND ts_ms<=? AND rowid<=?",
                        params: [min(current.lastNow, nowMs), max(current.lastNow, nowMs), oldCursor], row: SourceEvent.read)
                    counters.sourceRowsRead += newlyEffective.count
                    try invalidate(newlyEffective, calendar: calendar, policy: policy, cache: cache)
                }
                current.firstRow = first
                current.lastRow = last
                current.lastNow = nowMs
                try cache.run("INSERT OR REPLACE INTO metadata(id,json) VALUES(1,?)", [.blob(try JSONEncoder().encode(current))])
                let result = try work(db, cache, hasApp)
                return (result, dataVersion)
            }
        }
        // Do not advance in-memory validation until both transactions commit.
        lastDataVersion = completed.1
        return completed.0
    }

    private func ingest(_ rows: [SourceEvent], calendar: Calendar, policy: ActivityPolicy,
                        cache: DerivedDatabase) throws {
        var counts: [Int64: Int64] = [:]
        for row in rows {
            let start = ActivityCalculator.milliseconds(calendar.startOfDay(for: date(row.timestamp)))
            if row.kind == 0 { counts[start, default: 0] += 1 }
            if row.kind == 1, let span = ActivityCalculator.activitySpan(for: row.activity, policy: policy), span.startMs < start {
                try cache.run("INSERT OR REPLACE INTO crossing_releases(row_id,ts_ms,start_ms,json) VALUES(?,?,?,?)",
                    [.integer(row.rowID), .integer(row.timestamp), .integer(span.startMs), .blob(try JSONEncoder().encode(row))])
            }
        }
        for (day, count) in counts {
            try cache.run("INSERT INTO key_counts(day_start,count) VALUES(?,?) ON CONFLICT(day_start) DO UPDATE SET count=count+excluded.count",
                [.integer(day), .integer(count)])
        }
        try invalidate(rows, calendar: calendar, policy: policy, cache: cache)
    }

    private func invalidate(_ rows: [SourceEvent], calendar: Calendar, policy: ActivityPolicy,
                            cache: DerivedDatabase) throws {
        // Coalesce by event day; one DELETE per affected day, not per keystroke.
        var affected: [Int64: ActivitySpan] = [:]
        for row in rows {
            let day = calendar.startOfDay(for: date(row.timestamp))
            guard let end = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let startMs = ActivityCalculator.milliseconds(day)
            let span = ActivityCalculator.activitySpan(for: row.activity, policy: policy)
            let previous = affected[startMs]
            affected[startMs] = ActivitySpan(startMs: min(startMs, span?.startMs ?? startMs, previous?.startMs ?? startMs),
                endMs: max(ActivityCalculator.milliseconds(end), span?.endMs ?? row.timestamp, previous?.endMs ?? row.timestamp))
        }
        for span in ActivityCalculator.merge(Array(affected.values)) {
            try cache.run("DELETE FROM daily_summaries WHERE day_start<? AND day_end>?", [.integer(span.endMs), .integer(span.startMs)])
        }
    }

    private func summary(day: DateInterval, now: Date, calendar: Calendar, policy: ActivityPolicy,
                         db: Database, cache: DerivedDatabase, hasApp: Bool,
                         liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false) throws -> Summary {
        let start = ActivityCalculator.milliseconds(day.start)
        let end = ActivityCalculator.milliseconds(day.end)
        let nowMs = ActivityCalculator.milliseconds(now)
        let reusable = day.end <= now && !liveConnected
        if reusable, let saved: Summary = try cache.decoded("SELECT json FROM daily_summaries WHERE day_start=?", [.integer(start)]) {
            counters.dayCacheHits += 1
            return saved
        }
        var rows: [SourceEvent] = []
        if start < nowMs {
            let (lower, overflow) = start.subtractingReportingOverflow(max(0, policy.activityWindowMs))
            rows = try db.query("SELECT rowid,ts_ms,keycode,kind,hold_ms,\(hasApp ? "app" : "NULL") FROM key_events WHERE ts_ms>=? AND ts_ms<=? ORDER BY ts_ms,rowid",
                params: [overflow ? Int64.min : lower, min(end, nowMs)], row: SourceEvent.read)
            counters.sourceRowsRead += rows.count
            let crossing: [SourceEvent] = try cache.query("SELECT json FROM crossing_releases WHERE ts_ms>? AND ts_ms<=? AND start_ms<? ORDER BY ts_ms,row_id",
                [.integer(end), .integer(nowMs), .integer(end)]) { statement in
                    // Decode failures invalidate this cache request, never fabricate statistics.
                    try? JSONDecoder().decode(SourceEvent.self, from: DerivedDatabase.data(statement, 0))
                }.map { value in
                    guard let value else { throw CacheError.invalidPayload }
                    return value
                }
            rows.append(contentsOf: crossing)
        }
        let selection = ActivityRange.custom(CalendarDateRange(start: day.start, end: day.start, calendar: calendar))
        let activity = ActivityCalculator.snapshot(events: rows.map(\.activity), range: selection,
            now: now, calendar: calendar, policy: policy, liveEvents: liveEvents, liveConnected: liveConnected)
        guard let activityDay = activity.days.first else { throw CacheError.invalidPayload }
        let result = Summary(day: activityDay, keyCounts: activity.keyCounts,
            apps: appRanks(rows: rows, window: ActivitySpan(startMs: start, endMs: min(end, nowMs)), policy: policy))
        counters.daysComputed += 1
        if reusable {
            try cache.run("INSERT OR REPLACE INTO daily_summaries(day_start,day_end,json) VALUES(?,?,?)",
                [.integer(start), .integer(end), .blob(try JSONEncoder().encode(result))])
        }
        return result
    }

    private struct AppEventIdentity: Hashable {
        let app: String
        let event: ActivityKeyEvent
    }

    private func appRanks(rows: [SourceEvent], window: ActivitySpan, policy: ActivityPolicy) -> [AppRank] {
        var unique = Set<AppEventIdentity>()
        var spans: [String: [ActivitySpan]] = [:]
        var counts: [String: Int64] = [:]
        for row in rows {
            guard let app = row.app, row.timestamp <= window.endMs || row.kind == 1,
                  unique.insert(AppEventIdentity(app: app, event: row.activity)).inserted else { continue }
            if row.kind == 0, row.timestamp >= window.startMs, row.timestamp < window.endMs { counts[app, default: 0] += 1 }
            if let span = ActivityCalculator.activitySpan(for: row.activity, policy: policy)?.clipped(to: window) {
                spans[app, default: []].append(span)
            }
        }
        return Set(spans.keys).union(counts.keys).map { app in
            AppRank(app: app, usageMs: ActivityCalculator.merge(spans[app] ?? []).reduce(0) { $0 + $1.durationMs }, keyCount: counts[app] ?? 0)
        }
    }

    private func days(in interval: DateInterval, calendar: Calendar) -> [DateInterval] {
        var result: [DateInterval] = []
        var start = interval.start
        while start < interval.end {
            guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else { break }
            result.append(DateInterval(start: start, end: end))
            start = end
        }
        return result
    }

    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private func fileIdentity() throws -> String {
        let info = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        return "\(info[.systemNumber] ?? ""):\(info[.systemFileNumber] ?? ""):\(info[.creationDate] ?? "")"
    }

}

private enum CacheError: Error {
    case sqlite(Int32)
    case invalidPayload

    static func isCorruption(_ error: Error) -> Bool {
        if error is DecodingError { return true }
        guard let error = error as? CacheError else { return false }
        switch error {
        case .invalidPayload: return true
        case .sqlite(let code): return code & 0xff == SQLITE_CORRUPT || code & 0xff == SQLITE_NOTADB
        }
    }
}

/// Small writable store for derived data only; never opens the collector DB.
private final class DerivedDatabase {
    enum Value { case integer(Int64), blob(Data) }
    private let handle: OpaquePointer
    private var closed = false

    init(url: URL) throws {
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw CacheError.sqlite(code)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 100)
        do {
            try run("PRAGMA journal_mode=WAL")
            try run("PRAGMA synchronous=NORMAL")
            try run("CREATE TABLE IF NOT EXISTS metadata(id INTEGER PRIMARY KEY,json BLOB NOT NULL)")
            try run("CREATE TABLE IF NOT EXISTS daily_summaries(day_start INTEGER PRIMARY KEY,day_end INTEGER NOT NULL,json BLOB NOT NULL)")
            try run("CREATE TABLE IF NOT EXISTS crossing_releases(row_id INTEGER PRIMARY KEY,ts_ms INTEGER NOT NULL,start_ms INTEGER NOT NULL,json BLOB NOT NULL)")
            try run("CREATE INDEX IF NOT EXISTS crossing_end ON crossing_releases(ts_ms)")
            try run("CREATE TABLE IF NOT EXISTS key_counts(day_start INTEGER PRIMARY KEY,count INTEGER NOT NULL)")
        } catch {
            sqlite3_close(handle)
            closed = true
            throw error
        }
    }

    deinit { if !closed { sqlite3_close(handle) } }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try run("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    func run(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in 0 }
    }

    func decoded<T: Decodable>(_ sql: String, _ values: [Value] = []) throws -> T? {
        guard let data = try query(sql, values, row: { Self.data($0, 0) }).first else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func data(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func query<T>(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) -> T) throws -> [T] {
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &prepared, nil)
        guard code == SQLITE_OK, let prepared else { throw CacheError.sqlite(code) }
        defer { sqlite3_finalize(prepared) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let number): result = sqlite3_bind_int64(prepared, index, number)
            case .blob(let data): result = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(prepared, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            }
            guard result == SQLITE_OK else { throw CacheError.sqlite(result) }
        }
        var result: [T] = []
        while true {
            switch sqlite3_step(prepared) {
            case SQLITE_ROW: result.append(row(prepared))
            case SQLITE_DONE: return result
            case let code: throw CacheError.sqlite(code)
            }
        }
    }
}
