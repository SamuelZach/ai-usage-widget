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

    /// Hours under budget (positive) or over budget (negative): `headroom × window length`.
    /// Same metric the coarse `pace(at:)` thresholds use, expressed in absolute time.
    func paceHours(at now: Date) -> Double? {
        guard let h = headroom(at: now) else { return nil }
        return h * length / 3600
    }

    func pace(at now: Date) -> Pace {
        if locked || percent >= 100 { return .locked }
        guard let h = headroom(at: now) else { return .unknown }
        if h > 0.15 { return .underPace }
        if h < -0.10 { return .aheadOfPace }
        return .onTrack
    }

    /// Menu-bar color band from pace hours (positive = under / ahead of schedule).
    func paceColorBand(at now: Date) -> PaceColorBand? {
        guard !(locked || percent >= 100) else { return .moreThanDayOver }
        guard let hours = paceHours(at: now) else { return nil }
        return PaceColorBand.from(hours: hours)
    }
}

/// Fine-grained menu-bar colors by how many hours under (ahead) or over (behind) pace.
/// Under = under budget; over = over budget. Boundaries in hours of headroom × length.
enum PaceColorBand: Equatable {
    case moreThanDayUnder   // > 1 day under → light green
    case halfToDayUnder     // 12 h … 1 day under → dark green
    case upToHalfDayUnder   // just under … < 12 h under → light blue
    case upToHalfDayOver    // on-pace … < 12 h over → dark blue
    case halfToDayOver      // 12 h … < 1 day over → orange
    case moreThanDayOver    // ≥ 1 day over (or locked) → red

    static func from(hours: Double) -> PaceColorBand {
        if hours > 24 { return .moreThanDayUnder }
        if hours >= 12 { return .halfToDayUnder }
        if hours > 0 { return .upToHalfDayUnder }
        if hours > -12 { return .upToHalfDayOver }
        if hours > -24 { return .halfToDayOver }
        return .moreThanDayOver
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
    switch budget.pace(at: now) {
    case .underPace:
        return Advice(pace: .underPace, text: "Under pace — \(left)% left, resets in \(resets). Use it up.")
    case .aheadOfPace:
        return Advice(pace: .aheadOfPace, text: "Ahead of pace — \(left)% must last \(resets). Go easy.")
    case .onTrack:
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
