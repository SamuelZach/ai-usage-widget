import SwiftUI
import AppKit

extension Pace {
    var color: Color {
        switch self {
        case .underPace: return Color(red: 0.36, green: 0.85, blue: 0.55)
        case .onTrack: return Color(red: 0.55, green: 0.72, blue: 1.0)
        case .aheadOfPace: return Color(red: 1.0, green: 0.68, blue: 0.30)
        case .throttled: return Color(red: 1.0, green: 0.55, blue: 0.35)
        case .locked: return Color(red: 1.0, green: 0.40, blue: 0.42)
        case .unknown: return Color.white.opacity(0.55)
        }
    }
    var symbol: String {
        switch self {
        case .underPace: return "arrow.up.forward.circle.fill"
        case .onTrack: return "checkmark.circle.fill"
        case .aheadOfPace: return "tortoise.fill"
        case .throttled: return "hourglass.circle.fill"
        case .locked: return "lock.fill"
        case .unknown: return "exclamationmark.triangle.fill"
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PanelView: View {
    @EnvironmentObject var store: UsageStore
    /// ImageRenderer can't draw NSVisualEffectView; the --snapshot mode sets this.
    static var snapshotMode = false
    static let cardWidth: CGFloat = 340
    static let outerPadding: CGFloat = 20
    static var totalWidth: CGFloat { cardWidth + 2 * outerPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let best = bestBet(store.services, at: store.now) {
                bestBetBanner(best)
            }
            ForEach(store.services) { s in
                ServiceCard(service: s, stats: store.stats[s.id], now: store.now)
            }
            if store.services.isEmpty {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: Self.cardWidth)
        .background { if !Self.snapshotMode { VisualEffect() } }
        .background(Color.black.opacity(Self.snapshotMode ? 0.55 : 0.25))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(Self.outerPadding) // room for the shadow inside the transparent window
    }

    private var header: some View {
        HStack {
            Text("AI USAGE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(.secondary)
            Spacer()
            if store.refreshing {
                ProgressView().controlSize(.mini)
            } else if let t = store.lastRefresh {
                let age = store.now.timeIntervalSince(t)
                Text(age < 60 ? "updated just now" : "updated \(Fmt.duration(age)) ago")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func bestBetBanner(_ s: ServiceUsage) -> some View {
        let left = s.budgetWindow.map { Int((100 - $0.percent).rounded()) } ?? 0
        return HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Pace.underPace.color)
            Text("Best bet right now: ").foregroundStyle(.secondary)
            + Text(s.name).fontWeight(.semibold)
            + Text(" · \(left)% of \(s.budgetWindow?.label.lowercased() ?? "budget") left").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct ServiceCard: View {
    let service: ServiceUsage
    let stats: ServiceStats?
    let now: Date

    var body: some View {
        let adv = advice(for: service, at: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(adv.pace.color).frame(width: 8, height: 8)
                Text(service.name).font(.system(size: 13, weight: .semibold))
                if let plan = service.plan {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if service.error != nil, !service.windows.isEmpty {
                    Text("stale").font(.caption2).foregroundStyle(Pace.aheadOfPace.color)
                }
            }
            ForEach(service.windows) { w in
                WindowRow(window: w, now: now)
            }
            if let stats, stats.coverage != nil, !service.windows.isEmpty {
                ConsumptionRow(stats: stats, windowLabel: ServiceStats.trackedWindow(service).label, now: now)
            }
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: adv.pace.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(adv.pace.color)
                    .padding(.top, 1)
                Text(adv.text)
                    .font(.system(size: 11))
                    .foregroundStyle(adv.pace == .unknown ? Color.primary.opacity(0.7) : adv.pace.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let pace = window.pace(at: now)
        HStack(spacing: 8) {
            Text(window.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Bar(fraction: min(1, window.percent / 100), color: pace.color,
                elapsed: 1 - (window.timeLeftFraction(at: now) ?? 0))
            Text(Fmt.percent(window.percent))
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            HStack(spacing: 2) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 8))
                Text(Fmt.duration(window.remaining(at: now)))
                    .font(.system(size: 10).monospacedDigit())
            }
            .foregroundStyle(.tertiary)
            .frame(width: 58, alignment: .trailing)
        }
    }
}

/// Usage bar with a faint tick showing how far through the window we are, so
/// "bar ahead of tick" reads as ahead of pace at a glance.
struct Bar: View {
    let fraction: Double
    let color: Color
    let elapsed: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(color).frame(width: max(fraction > 0 ? 6 : 0, g.size.width * fraction))
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 1.5, height: 10)
                    .offset(x: g.size.width * min(max(elapsed, 0), 1) - 0.75)
            }
        }
        .frame(height: 6)
    }
}

/// "↑ 14% in last 5 h · 31% today" with a 24-hour sparkline of hourly consumption.
struct ConsumptionRow: View {
    let stats: ServiceStats
    let windowLabel: String
    let now: Date

    private func pct(_ v: Double) -> String {
        // Sub-point moves matter on a weekly budget, so keep a decimal — but only a real one.
        if v < 0.05 { return "0%" }
        if v < 10, abs(v - v.rounded()) > 0.05 { return String(format: "%.1f%%", v) }
        return "\(Int(v.rounded()))%"
    }

    var body: some View {
        // Don't claim "last 5 h" before we have five hours of history at all.
        let start = stats.coverage ?? now
        let shortHistory = now.timeIntervalSince(start) < 5 * 3600
        let sinceLabel = shortHistory ? "since \(Fmt.dayTime.string(from: start).suffix(5))" : "in last 5 h"
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Sparkline(values: stats.hourly24)
                    .frame(width: 72, height: 14)
                    .help("Hourly use of the \(windowLabel.lowercased()) allowance over the last 24 h")
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                Text("\(pct(stats.last5h)) \(sinceLabel) · \(pct(stats.today)) today")
                    .font(.system(size: 10).monospacedDigit())
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.tertiary)
        .padding(.top, 1)
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 0, 1)
            let n = max(values.count, 1)
            let slot = g.size.width / CGFloat(n)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(v > 0 ? Color.white.opacity(0.7) : Color.white.opacity(0.12))
                        .frame(width: max(slot - 1, 1), height: max(2, g.size.height * CGFloat(v / maxV)))
                        .frame(width: slot, alignment: .bottom)
                }
            }
            .frame(height: g.size.height, alignment: .bottom)
        }
    }
}
