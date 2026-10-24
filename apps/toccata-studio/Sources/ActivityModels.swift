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

enum ActivityRange: String, CaseIterable, Identifiable {
    case today = "今日"
    case lastSevenDays = "最近 7 天"
    case thisWeek = "本周"

    var id: String { rawValue }

    func interval(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start: Date
        switch self {
        case .today: start = today
        case .lastSevenDays: start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .thisWeek:
            // Weekly reporting uses Monday through Sunday, independent of the
            // locale's display preference for the first weekday.
            let weekday = calendar.component(.weekday, from: today)
            start = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: today) ?? today
        }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        return DateInterval(start: start, end: end)
    }
}

struct ActivityPolicy: Equatable {
    var idleGapMs: Int64 = 60_000
    var trailingGraceMs: Int64 = 5_000

    static func load(configURL: URL? = nil) -> ActivityPolicy {
        let url = configURL ?? AppPaths.supportDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ActivityPolicy()
        }
        var policy = ActivityPolicy()
        // Match the daemon's unsigned integer configuration contract. A bad
        // field leaves the default in place rather than changing the metric.
        func milliseconds(_ key: String, fallback: Int64) -> Int64 {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value.rounded() == value,
                  value <= Double(Int64.max / 1000) else { return fallback }
            return Int64(value) * 1000
        }
        policy.idleGapMs = milliseconds("idle_gap_secs", fallback: policy.idleGapMs)
        policy.trailingGraceMs = milliseconds("trailing_grace_secs", fallback: policy.trailingGraceMs)
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

struct ActivityBucket: Identifiable {
    let startMs: Int64
    let endMs: Int64
    let activeMs: Int64
    let keyCount: Int
    var id: Int64 { startMs }
    var fraction: Double {
        guard endMs > startMs else { return 0 }
        return min(1, Double(activeMs) / Double(endMs - startMs))
    }
}

struct ActivityDay: Identifiable {
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
    var errorMessage: String?
}

/// Pure interval reconstruction. Completed holds and live holds are unioned
/// with event sessions, so chords never add duplicate time.
enum ActivityCalculator {
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
        var first: Int64?
        var last: Int64?

        func appendSession() {
            guard let first, let last else { return }
            active.append(ActivitySpan(startMs: first, endMs: min(nowMs, last + policy.trailingGraceMs)))
        }
        for event in ordered {
            if let previous = last, event.timestampMs - previous >= policy.idleGapMs {
                appendSession()
                first = event.timestampMs
            } else if first == nil { first = event.timestampMs }
            last = event.timestampMs
            if event.kind == 1, let duration = event.holdMs, duration >= 0 {
                let start = event.timestampMs - duration
                if start <= event.timestampMs {
                    let hold = ActivitySpan(startMs: start, endMs: event.timestampMs)
                    active.append(hold)
                    if event.keycode == 63 { voice.append(hold) }
                }
            }
        }
        appendSession()
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
                    keyCount: bucketKeys
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
            fnMs: voice.reduce(0) { $0 + $1.durationMs }, keyCount: downs.count)
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
