import Foundation
import SQLite3

/// Append-only log of every usage sample, so we can answer "how much did I use in the last N hours".
/// Consumption is derived from the *level* samples: sum of positive deltas between consecutive
/// samples (a drop means the window reset, and is ignored).
@MainActor
final class History {
    static let shared = History()

    struct Point: Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    private var db: OpaquePointer?
    let fileURL: URL

    /// Sampling pauses whenever the Mac sleeps, so gaps of tens of minutes are routine and say
    /// nothing about usage. A rise seen after any gap is still real usage — it just happened at
    /// some unknown point inside the gap. Totals therefore count every rise, and the charts
    /// spread a gap-spanning rise across the hours it covers instead of spiking the bucket where
    /// we happened to wake up.

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = ProcessInfo.processInfo.environment["AIUSAGE_DB"].map { URL(fileURLWithPath: $0) }
            ?? dir.appendingPathComponent("history.sqlite")
        if sqlite3_open(fileURL.path, &db) == SQLITE_OK {
            exec("""
            CREATE TABLE IF NOT EXISTS samples (
                ts REAL NOT NULL, service TEXT NOT NULL, window TEXT NOT NULL,
                percent REAL NOT NULL, resets_at REAL);
            CREATE INDEX IF NOT EXISTS idx_samples ON samples(service, window, ts);
            """)
        } else {
            db = nil
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    // MARK: - Writing

    func record(_ services: [ServiceUsage], at now: Date = Date()) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO samples (ts, service, window, percent, resets_at) VALUES (?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        exec("BEGIN")
        for s in services where s.error == nil {
            for w in s.windows {
                sqlite3_reset(stmt)
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, s.id, -1, transient)
                sqlite3_bind_text(stmt, 3, w.id, -1, transient)
                sqlite3_bind_double(stmt, 4, w.percent)
                if let r = w.resetsAt { sqlite3_bind_double(stmt, 5, r.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 5) }
                sqlite3_step(stmt)
            }
        }
        exec("COMMIT")
    }

    // MARK: - Reading

    /// Level samples for one service/window, including the last sample *before* `since`
    /// so the first delta inside the range can be attributed.
    func samples(service: String, window: String, since: Date) -> [Point] {
        guard let db else { return [] }
        var out: [Point] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT ts, percent FROM samples WHERE service = ? AND window = ? AND ts >= COALESCE(
            (SELECT MAX(ts) FROM samples WHERE service = ? AND window = ? AND ts < ?), ?)
        ORDER BY ts
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, service, -1, transient)
        sqlite3_bind_text(stmt, 2, window, -1, transient)
        sqlite3_bind_text(stmt, 3, service, -1, transient)
        sqlite3_bind_text(stmt, 4, window, -1, transient)
        sqlite3_bind_double(stmt, 5, since.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 6, since.timeIntervalSince1970)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Point(date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                             value: sqlite3_column_double(stmt, 1)))
        }
        return out
    }

    func earliestSample(service: String) -> Date? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM samples WHERE service = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, service, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    /// Percentage points consumed since `since` (every rise counts; drops are window resets).
    func consumed(service: String, window: String, since: Date) -> Double {
        let pts = samples(service: service, window: window, since: since)
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count where pts[i].date >= since {
            total += max(0, pts[i].value - pts[i - 1].value)
        }
        return total
    }

    /// Consumption per time bucket, oldest first. `count` buckets of `size` seconds ending at `end`.
    func buckets(service: String, window: String, end: Date, size: TimeInterval, count: Int) -> [Point] {
        let start = end.addingTimeInterval(-size * Double(count))
        let pts = samples(service: service, window: window, since: start)
        var values = [Double](repeating: 0, count: count)
        if pts.count > 1 {
            for i in 1..<pts.count {
                let rise = pts[i].value - pts[i - 1].value
                guard rise > 0 else { continue }
                // Spread the rise over [previous sample, this sample], weighted by how much of
                // that span falls in each bucket. A normal 2-minute step lands in one bucket;
                // a rise first seen after a long sleep is spread over the whole sleep.
                let from = max(pts[i - 1].date.timeIntervalSince(start), 0)
                let to = min(pts[i].date.timeIntervalSince(start), size * Double(count))
                guard to > from else { continue }
                let span = to - from
                for b in Int(from / size)...Int(min(to, size * Double(count) - 0.001) / size) where b >= 0 && b < count {
                    let lo = max(from, size * Double(b)), hi = min(to, size * Double(b + 1))
                    if hi > lo { values[b] += rise * (hi - lo) / span }
                }
            }
        }
        return values.enumerated().map { Point(date: start.addingTimeInterval(size * Double($0.offset)), value: $0.element) }
    }

    func exportCSV(to url: URL) throws {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ts, service, window, percent, resets_at FROM samples ORDER BY ts", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var csv = "timestamp,service,window,percent,resets_at\n"
        let iso = ISO8601DateFormatter()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let ts = iso.string(from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)))
            let service = String(cString: sqlite3_column_text(stmt, 1))
            let window = String(cString: sqlite3_column_text(stmt, 2))
            let pct = sqlite3_column_double(stmt, 3)
            let reset = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? "" : iso.string(from: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)))
            csv += "\(ts),\(service),\(window),\(pct),\(reset)\n"
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Derived numbers shown in the panel; recomputed after every refresh.
struct ServiceStats {
    let last5h: Double
    let today: Double
    let hourly24: [Double]   // consumption per hour, oldest first
    let coverage: Date?      // earliest sample we have for this service

    /// The window whose level we track for consumption — the longest one that isn't monthly.
    /// Falls back to "week" so history still renders while the live fetch is failing.
    static func trackedWindow(_ s: ServiceUsage) -> (id: String, label: String) {
        if let w = s.windows.filter({ $0.id != "month" }).max(by: { $0.length < $1.length }) ?? s.budgetWindow {
            return (w.id, w.label)
        }
        return ("week", "Week")
    }

    @MainActor
    static func compute(for s: ServiceUsage, at now: Date) -> ServiceStats {
        let w = trackedWindow(s)
        let h = History.shared
        let startOfDay = Calendar.current.startOfDay(for: now)
        return ServiceStats(
            last5h: h.consumed(service: s.id, window: w.id, since: now.addingTimeInterval(-5 * 3600)),
            today: h.consumed(service: s.id, window: w.id, since: startOfDay),
            hourly24: h.buckets(service: s.id, window: w.id, end: now, size: 3600, count: 24).map(\.value),
            coverage: h.earliestSample(service: s.id))
    }
}
