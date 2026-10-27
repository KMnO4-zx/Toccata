import Foundation
import CoreFoundation

/// Event identity is timestamp + keycode + kind. A live event can later gain its
/// persisted hold duration without counting the same key twice.
struct ActivityKeyEvent: Equatable, Hashable {
    let timestampMs: Int64
    let keycode: Int
    let kind: Int
    var holdMs: Int64? = nil
}

enum ActivityRange: Hashable, CaseIterable, Identifiable {
    case today
    case yesterday
    case lastSevenDays
    case thisWeek
    case custom(CalendarDateRange)

    static let allCases: [ActivityRange] = [.today, .yesterday, .lastSevenDays, .thisWeek]

    var id: Self { self }

    var rawValue: String {
        switch self {
        case .today: return L10n.tr("今日")
        case .yesterday: return L10n.tr("昨日")
        case .lastSevenDays: return L10n.tr("最近 7 天")
        case .thisWeek: return L10n.tr("本周")
        case .custom: return L10n.tr("自定义时段")
        }
    }

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start: Date
        switch self {
        case .today: start = today
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            return DateInterval(start: yesterday, end: today)
        case .lastSevenDays: start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .thisWeek:
            // Weekly reporting uses Monday through Sunday, independent of the
            // locale's display preference for the first weekday.
            let weekday = calendar.component(.weekday, from: today)
            start = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        case .custom(let dates):
            return dates.interval(calendar: calendar)
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return DateInterval(start: start, end: end)
    }
}

struct ActivityPolicy: Equatable {
    var activityWindowMs: Int64 = 5_000

    static func load(configURL: URL? = nil) -> ActivityPolicy {
        let url = configURL ?? AppPaths.supportDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ActivityPolicy()
        }
        var policy = ActivityPolicy()
        // A bad field leaves the default in place rather than changing the metric.
        func milliseconds(_ key: String, fallback: Int64) -> Int64 {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, let seconds = Int64(exactly: value) else { return fallback }
            let (result, overflow) = seconds.multipliedReportingOverflow(by: 1000)
            return overflow ? fallback : result
        }
        policy.activityWindowMs = milliseconds("activity_window_secs", fallback: policy.activityWindowMs)
        return policy
    }
}

struct ActivitySpan: Equatable {
    let startMs: Int64
    let endMs: Int64
    var durationMs: Int64 { max(0, endMs - startMs) }

    func clipped(to other: ActivitySpan) -> ActivitySpan? {
        let start = max(startMs, other.startMs)
        let end = min(endMs, other.endMs)
        return end > start ? ActivitySpan(startMs: start, endMs: end) : nil
    }
}

struct ActivityBucket: Identifiable, Codable {
    let startMs: Int64
    let endMs: Int64
    let activeMs: Int64
    let keyCount: Int
    var fnMs: Int64 = 0
    var id: Int64 { startMs }
    var fraction: Double {
        guard endMs > startMs else { return 0 }
        return min(1, Double(activeMs) / Double(endMs - startMs))
    }
}

struct ActivityDay: Identifiable, Codable {
    let date: Date
    let activeMs: Int64
    let fnMs: Int64
    let keyCount: Int
    let buckets: [ActivityBucket]
    var id: Date { date }
}

struct ActivitySnapshot {
    var days: [ActivityDay] = []
    var activeMs: Int64 = 0
    var fnMs: Int64 = 0
    var keyCount = 0
    var keyCounts: [Int: Int] = [:]
    var errorMessage: String?
}

/// Pure interval reconstruction. Completed holds and live holds are unioned
/// with short key-down windows, so chords never add duplicate time.
enum ActivityCalculator {
    /// Releases only contribute their actual hold; they never start another
    /// activity window. App rankings apply the same policy inside SQLite.
    static func activitySpan(for event: ActivityKeyEvent, policy: ActivityPolicy) -> ActivitySpan? {
        if event.kind == 0 {
            let (end, overflow) = event.timestampMs.addingReportingOverflow(max(0, policy.activityWindowMs))
            return ActivitySpan(startMs: event.timestampMs, endMs: overflow ? Int64.max : end)
        }
        if event.kind == 1, let duration = event.holdMs, duration > 0 {
            let (start, overflow) = event.timestampMs.subtractingReportingOverflow(duration)
            return ActivitySpan(startMs: overflow ? Int64.min : start, endMs: event.timestampMs)
        }
        return nil
    }

    static func merge(_ spans: [ActivitySpan]) -> [ActivitySpan] {
        let ordered = spans.filter { $0.durationMs > 0 }.sorted { $0.startMs < $1.startMs }
        var result: [ActivitySpan] = []
        for span in ordered {
            if let last = result.last, span.startMs <= last.endMs {
                result[result.count - 1] = ActivitySpan(startMs: last.startMs, endMs: max(last.endMs, span.endMs))
            } else {
                result.append(span)
            }
        }
        return result
    }

    static func openLiveKeys(_ events: [ActivityKeyEvent]) -> [Int: Int64] {
        var pressed: [Int: Int64] = [:]
        for event in events.sorted(by: eventOrder) {
            if event.kind == 0, pressed[event.keycode] == nil { pressed[event.keycode] = event.timestampMs }
            else if event.kind == 1 { pressed.removeValue(forKey: event.keycode) }
        }
        return pressed
    }

    static func snapshot(
        events: [ActivityKeyEvent], range: ActivityRange, now: Date,
        calendar: Calendar = .current, policy: ActivityPolicy = ActivityPolicy(),
        liveEvents: [ActivityKeyEvent] = [], liveConnected: Bool = false
    ) -> ActivitySnapshot {
        let interval = range.interval(now: now, calendar: calendar)
        let nowMs = milliseconds(now)
        let window = ActivitySpan(startMs: milliseconds(interval.start), endMs: min(milliseconds(interval.end), nowMs))
        let validLive = liveConnected ? liveEvents.filter { $0.timestampMs <= nowMs } : []
        let ordered = deduplicated(events + validLive).filter { $0.timestampMs <= nowMs }.sorted(by: eventOrder)
        var active: [ActivitySpan] = []
        var voice: [ActivitySpan] = []
        for event in ordered {
            if let span = activitySpan(for: event, policy: policy) {
                active.append(span)
                if event.kind == 1, event.keycode == 63 { voice.append(span) }
            }
        }
        // A persisted, orphaned down may be left behind by a daemon crash.
        // Only down events witnessed during this live connection can grow.
        if liveConnected {
            var pressed: [Int: Int64] = [:]
            for event in validLive.sorted(by: eventOrder) {
                if event.kind == 0, pressed[event.keycode] == nil {
                    pressed[event.keycode] = event.timestampMs
                } else if event.kind == 1, let start = pressed.removeValue(forKey: event.keycode) {
                    let hold = ActivitySpan(startMs: start, endMs: event.timestampMs)
                    active.append(hold)
                    if event.keycode == 63 { voice.append(hold) }
                }
            }
            for (keycode, start) in pressed {
                let hold = ActivitySpan(startMs: start, endMs: nowMs)
                active.append(hold)
                if keycode == 63 { voice.append(hold) }
            }
        }
        active = merge(active.compactMap { $0.clipped(to: window) })
        voice = merge(voice.compactMap { $0.clipped(to: window) })
        let downs = ordered.filter { $0.kind == 0 && $0.timestampMs >= window.startMs && $0.timestampMs < window.endMs }
        let keyCounts = downs.reduce(into: [Int: Int]()) { counts, event in
            counts[event.keycode, default: 0] += 1
        }

        var days: [ActivityDay] = []
        var dayStart = interval.start
        while dayStart < interval.end {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart), dayEnd > dayStart else { break }
            let day = ActivitySpan(startMs: milliseconds(dayStart), endMs: milliseconds(dayEnd))
            let dayActive = active.compactMap { $0.clipped(to: day) }
            let dayVoice = voice.compactMap { $0.clipped(to: day) }
            let dayDowns = downs.filter { $0.timestampMs >= day.startMs && $0.timestampMs < day.endMs }
            var buckets: [ActivityBucket] = []
            var bucketStart = dayStart
            var downIndex = 0
            while bucketStart < dayEnd {
                let bucketEnd = min(bucketStart.addingTimeInterval(15 * 60), dayEnd)
                let bucket = ActivitySpan(startMs: milliseconds(bucketStart), endMs: milliseconds(bucketEnd))
                var bucketKeys = 0
                while downIndex < dayDowns.count && dayDowns[downIndex].timestampMs < bucket.endMs {
                    bucketKeys += 1
                    downIndex += 1
                }
                buckets.append(ActivityBucket(
                    startMs: bucket.startMs, endMs: bucket.endMs,
                    activeMs: dayActive.compactMap { $0.clipped(to: bucket) }.reduce(0) { $0 + $1.durationMs },
                    keyCount: bucketKeys,
                    fnMs: dayVoice.compactMap { $0.clipped(to: bucket) }.reduce(0) { $0 + $1.durationMs }
                ))
                bucketStart = bucketEnd
            }
            days.append(ActivityDay(date: dayStart,
                activeMs: dayActive.reduce(0) { $0 + $1.durationMs },
                fnMs: dayVoice.reduce(0) { $0 + $1.durationMs },
                keyCount: dayDowns.count, buckets: buckets))
            dayStart = dayEnd
        }
        return ActivitySnapshot(days: days, activeMs: active.reduce(0) { $0 + $1.durationMs },
            fnMs: voice.reduce(0) { $0 + $1.durationMs }, keyCount: downs.count, keyCounts: keyCounts)
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    private struct EventIdentity: Hashable {
        let timestampMs: Int64
        let keycode: Int
        let kind: Int
    }

    private static func deduplicated(_ events: [ActivityKeyEvent]) -> [ActivityKeyEvent] {
        var unique: [EventIdentity: ActivityKeyEvent] = [:]
        for event in events {
            let identity = EventIdentity(timestampMs: event.timestampMs, keycode: event.keycode, kind: event.kind)
            if let existing = unique[identity], existing.holdMs != nil { continue }
            unique[identity] = event
        }
        return Array(unique.values)
    }

    private static func eventOrder(_ lhs: ActivityKeyEvent, _ rhs: ActivityKeyEvent) -> Bool {
        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs < rhs.timestampMs }
        if lhs.keycode != rhs.keycode { return lhs.keycode < rhs.keycode }
        return lhs.kind < rhs.kind
    }
}
