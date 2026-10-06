import SwiftUI
import Charts

struct HistoryView: View {
    @EnvironmentObject var store: UsageStore

    enum Range: String, CaseIterable, Identifiable {
        case day = "24 hours", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var bucket: TimeInterval { self == .day ? 3600 : 86400 }
        var count: Int { switch self { case .day: 24; case .week: 7; case .month: 30 } }
        var unit: Calendar.Component { self == .day ? .hour : .day }
    }

    @State private var range: Range = .day
    /// ImageRenderer can't draw the picker/scroll view; --snapshot-history uses this.
    static var snapshotMode = false
    /// Debug: AIUSAGE_HOVER=<bucket index> renders the hover tooltip in snapshots.
    static var snapshotHoverIndex: Int? {
        snapshotMode ? ProcessInfo.processInfo.environment["AIUSAGE_HOVER"].flatMap(Int.init) : nil
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(store.services) { s in
                ServiceHistory(service: s, range: range, now: store.now, tick: store.lastRefresh)
            }
            if let first = store.services.compactMap({ History.shared.earliestSample(service: $0.id) }).min() {
                Text("Recording since \(first.formatted(date: .abbreviated, time: .shortened)). Samples every 2 min while the app runs; usage while it was closed can't be placed on the timeline.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if Self.snapshotMode {
                    Text(range.rawValue).font(.headline)
                } else {
                    Picker("", selection: $range) {
                        ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
                Spacer()
                Text("Percent of each plan's allowance used per \(range == .day ? "hour" : "day")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if Self.snapshotMode { content } else { ScrollView { content } }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 520)
    }
}

private struct ServiceHistory: View {
    let service: ServiceUsage
    let range: HistoryView.Range
    let now: Date
    let tick: Date?   // forces recompute after each refresh

    /// Date under the mouse pointer, nil when not hovering.
    @State private var hovered: Date?

    private static let cal = Calendar.current
    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Buckets aligned to whole hours/days so a bar labelled 13:00 really covers 13:00–14:00.
    private var points: [History.Point] {
        let tracked = ServiceStats.trackedWindow(service)
        let end = Self.cal.dateInterval(of: range.unit, for: now)?.end ?? now
        return History.shared.buckets(service: service.id, window: tracked.id, end: end,
                                      size: range.bucket, count: range.count)
    }

    private func pct(_ v: Double) -> String {
        if v < 0.05 { return "0%" }
        if v < 10, abs(v - v.rounded()) > 0.05 { return String(format: "%.1f%%", v) }
        return "\(Int(v.rounded()))%"
    }

    private func label(for p: History.Point) -> String {
        let end = p.date.addingTimeInterval(range.bucket)
        if range == .day {
            let day = p.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let from = Self.hhmm.string(from: p.date)
            let to = Self.hhmm.string(from: end)
            return "\(day) · \(from)–\(to)"
        }
        return p.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    var body: some View {
        let tracked = ServiceStats.trackedWindow(service)
        let points = self.points
        let total = points.reduce(0) { $0 + $1.value }
        let color = advice(for: service, at: now).pace.color
        let selected = hovered.flatMap { h in
            points.first { Self.cal.isDate($0.date, equalTo: h, toGranularity: range.unit) }
        } ?? HistoryView.snapshotHoverIndex.flatMap { points.indices.contains($0) ? points[$0] : nil }

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(service.name).font(.headline)
                Text("· \(tracked.label.lowercased()) allowance").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(pct(total)) used in the last \(range.rawValue)")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Time", p.date, unit: range.unit),
                            y: .value("Used", p.value))
                    .foregroundStyle(color.gradient)
                    .cornerRadius(2)
                    .opacity(selected == nil || selected?.date == p.date ? 1 : 0.35)
                }
                if let sel = selected {
                    RuleMark(x: .value("Time", sel.date, unit: range.unit))
                        .foregroundStyle(Color.primary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label(for: sel))
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(sel.value < 0.05 ? "Nothing used" : "\(pct(sel.value)) of \(tracked.label.lowercased()) allowance")
                                    .font(.system(.caption, design: .rounded).weight(.semibold))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(pct(d)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: range.unit, count: range == .day ? 4 : (range == .week ? 1 : 5))) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.day().month(.abbreviated))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geo[plot].origin.x
                                guard x >= 0, x <= geo[plot].width else { hovered = nil; return }
                                hovered = proxy.value(atX: x, as: Date.self)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 150)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .id(tick)
    }
}
