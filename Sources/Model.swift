import Foundation

/// How the current burn rate compares with the time left in the window.
enum Pace {
    case underPace   // plenty left for the time remaining — use it up
    case onTrack
    case aheadOfPace // will run out before the reset — go easy
    case throttled   // short window nearly exhausted
    case locked      // a limit has been hit
    case unknown     // no data / error
}

struct UsageWindow: Identifiable {
    let id: String          // "5h", "week", "month"
    let label: String
    let percent: Double     // 0...100
    let resetsAt: Date?
    let length: TimeInterval
    let locked: Bool

    func remaining(at now: Date) -> TimeInterval? {
        resetsAt.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Fraction of the window still ahead of us (0...1).
    func timeLeftFraction(at now: Date) -> Double? {
        remaining(at: now).map { min(1, $0 / length) }
    }

    /// Budget left minus time left. Positive = under pace, negative = ahead of pace.
    func headroom(at now: Date) -> Double? {
        guard let t = timeLeftFraction(at: now) else { return nil }
        return (100 - percent) / 100 - t
    }

    /// How far usage sits from an even burn, as a duration of this window.
    /// Positive = ahead of pace. Day 2 of a 10-day window at 40% used is +2 days,
    /// because that usage is what an even burn would reach on day 4.
    /// Negative = under pace, by that much spare allowance.
    func paceInterval(at now: Date) -> TimeInterval? {
        guard let h = headroom(at: now) else { return nil }
        return -h * length
    }

    func pace(at now: Date) -> Pace {
        if locked || percent >= 100 { return .locked }
        guard let h = headroom(at: now) else { return .unknown }
        if h > 0.15 { return .underPace }
        if h < -0.10 { return .aheadOfPace }
        return .onTrack
    }
}

struct ServiceUsage: Identifiable {
    let id: String
    let name: String
    let plan: String?
    let windows: [UsageWindow]
    let error: String?
    let fetchedAt: Date

    static func failed(_ id: String, _ name: String, _ message: String) -> ServiceUsage {
        ServiceUsage(id: id, name: name, plan: nil, windows: [], error: message, fetchedAt: Date())
    }

    /// The window that acts as the real budget: the longest one.
    var budgetWindow: UsageWindow? { windows.max { $0.length < $1.length } }
    var shortWindow: UsageWindow? { windows.min { $0.length < $1.length } }
}

struct Advice {
    let pace: Pace
    let text: String
}

enum Fmt {
    static func duration(_ t: TimeInterval?) -> String {
        guard let t else { return "—" }
        let m = Int(t / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(m % 60)m" }
        let d = h / 24
        return "\(d)d \(h % 24)h"
    }

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "EEE d MMM"
        return f
    }()

    static func reset(_ d: Date?, at now: Date) -> String {
        guard let d else { return "—" }
        let t = d.timeIntervalSince(now)
        if t < 36 * 3600 { return dayTime.string(from: d) }
        return dateOnly.string(from: d)
    }

    static func percent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

    /// "2 days ahead" / "6 hours under" / "on pace". Positive interval is ahead of pace.
    static func paceDelta(_ interval: TimeInterval) -> String {
        if abs(interval) < 30 * 60 { return "on pace" }
        let side = interval > 0 ? "ahead" : "under"
        return "\(paceSpan(interval)) \(side)"
    }

    /// Menu-bar form: one unit only, "2d over" or "6h under".
    static func paceMark(_ interval: TimeInterval) -> String? {
        if abs(interval) < 30 * 60 { return nil }
        let side = interval > 0 ? "over" : "under"
        let minutes = Int((abs(interval) / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1))m \(side)" }
        let hours = Int((abs(interval) / 3600).rounded())
        if hours < 24 { return "\(hours)h \(side)" }
        let days = max(1, Int((abs(interval) / 86400).rounded()))
        return "\(days)d \(side)"
    }

    /// Whole days and hours read as words; mixed amounts stay short ("1d 16h").
    static func paceSpan(_ interval: TimeInterval, compact: Bool = false) -> String {
        let minutes = max(1, Int((abs(interval) / 60).rounded()))
        if minutes < 60 {
            if compact { return "\(minutes)m" }
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let hours = Int((abs(interval) / 3600).rounded())
        if hours < 24 {
            if compact { return "\(hours)h" }
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let days = hours / 24
        let rem = hours % 24
        if rem == 0 {
            if compact { return "\(days)d" }
            return days == 1 ? "1 day" : "\(days) days"
        }
        return "\(days)d \(rem)h"
    }
}

/// Budget-window gap for a subscription, when we actually know where it stands.
/// `interval` is positive when ahead of pace.
func paceGap(for s: ServiceUsage, at now: Date) -> (interval: TimeInterval, pace: Pace)? {
    guard let window = s.budgetWindow, let interval = window.paceInterval(at: now) else { return nil }
    let pace = window.pace(at: now)
    guard pace == .underPace || pace == .onTrack || pace == .aheadOfPace else { return nil }
    return (interval, pace)
}

func advice(for s: ServiceUsage, at now: Date) -> Advice {
    if let e = s.error { return Advice(pace: .unknown, text: e) }

    if let hit = s.windows.first(where: { $0.locked || $0.percent >= 100 }) {
        let back = hit.resetsAt.map { "back \(Fmt.reset($0, at: now))" } ?? "reset time unknown"
        return Advice(pace: .locked, text: "\(hit.label) limit hit — \(back)")
    }

    if let short = s.shortWindow, short.percent >= 85 {
        return Advice(pace: .throttled,
                      text: "\(short.label) window almost used — frees up in \(Fmt.duration(short.remaining(at: now)))")
    }

    guard let budget = s.budgetWindow else {
        return Advice(pace: .unknown, text: "No usage windows reported")
    }
    let left = Int((100 - budget.percent).rounded())
    let resets = Fmt.duration(budget.remaining(at: now))
    let by: String = {
        guard let interval = budget.paceInterval(at: now), abs(interval) >= 30 * 60 else { return "" }
        return " by \(Fmt.paceSpan(interval))"
    }()
    switch budget.pace(at: now) {
    case .underPace:
        return Advice(pace: .underPace, text: "Under pace\(by) — \(left)% left, resets in \(resets). Use it up.")
    case .aheadOfPace:
        return Advice(pace: .aheadOfPace, text: "Ahead of pace\(by) — \(left)% must last \(resets). Go easy.")
    case .onTrack:
        if let interval = budget.paceInterval(at: now), Fmt.paceDelta(interval) != "on pace" {
            return Advice(pace: .onTrack, text: "On track, \(Fmt.paceDelta(interval)) — \(left)% left, resets in \(resets).")
        }
        return Advice(pace: .onTrack, text: "On track — \(left)% left, resets in \(resets).")
    default:
        return Advice(pace: .unknown, text: "\(left)% left")
    }
}

/// Which service to reach for right now: the one with the most budget headroom that isn't blocked.
func bestBet(_ services: [ServiceUsage], at now: Date) -> ServiceUsage? {
    services
        .filter { s in
            s.error == nil && ![.locked, .throttled].contains(advice(for: s, at: now).pace)
        }
        .max { a, b in
            (a.budgetWindow?.headroom(at: now) ?? -1) < (b.budgetWindow?.headroom(at: now) ?? -1)
        }
}
