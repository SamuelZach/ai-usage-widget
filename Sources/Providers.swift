import Foundation

enum ProviderError: Error {
    case http(Int)
    case parse
}

enum Providers {
    // MARK: - Helpers

    /// Reads a generic password via the `security` CLI. Going through the CLI means the
    /// existing keychain ACLs (already granted to `security`) keep working without prompts.
    static func keychain(service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    static func get(_ url: String, headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 15
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ProviderError.http(code) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse
        }
        return json
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static func describe(_ error: Error, loginHint: String) -> String {
        if case ProviderError.http(let code) = error {
            if code == 401 || code == 403 { return "Login expired — \(loginHint)" }
            if code == 429 { return "Rate limited by the usage API — retrying shortly" }
            return "Server returned \(code)"
        }
        if case ProviderError.parse = error { return "Unexpected response" }
        return "Offline"
    }

    // MARK: - Claude (Claude Code OAuth)

    static func claude() async -> ServiceUsage {
        let id = "claude", name = "Claude"
        guard let raw = keychain(service: "Claude Code-credentials"),
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return .failed(id, name, "No Claude Code login found") }

        let plan = (oauth["subscriptionType"] as? String).map { $0.capitalized }
        do {
            let j = try await get("https://api.anthropic.com/api/oauth/usage", headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
            var windows: [UsageWindow] = []
            if let w = j["five_hour"] as? [String: Any] {
                windows.append(UsageWindow(id: "5h", label: "5 h",
                                           percent: w["utilization"] as? Double ?? 0,
                                           resetsAt: date(w["resets_at"]), length: 5 * 3600,
                                           locked: w["locked_reason"] != nil && !(w["locked_reason"] is NSNull)))
            }
            if let w = j["seven_day"] as? [String: Any] {
                windows.append(UsageWindow(id: "week", label: "Week",
                                           percent: w["utilization"] as? Double ?? 0,
                                           resetsAt: date(w["resets_at"]), length: 7 * 86400,
                                           locked: w["locked_reason"] != nil && !(w["locked_reason"] is NSNull)))
            }
            return ServiceUsage(id: id, name: name, plan: plan, windows: windows, error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Claude Code once"))
        }
    }

    // MARK: - Codex / ChatGPT

    static func codex() async -> ServiceUsage {
        let id = "codex", name = "Codex"
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String
        else { return .failed(id, name, "No Codex login found (~/.codex/auth.json)") }

        var headers = ["Authorization": "Bearer \(token)"]
        if let acct = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = acct }

        do {
            let j = try await get("https://chatgpt.com/backend-api/wham/usage", headers: headers)
            let plan = (j["plan_type"] as? String).map { $0.capitalized }
            var windows: [UsageWindow] = []
            if let rl = j["rate_limit"] as? [String: Any] {
                let reached = rl["limit_reached"] as? Bool ?? false
                for key in ["primary_window", "secondary_window"] {
                    guard let w = rl[key] as? [String: Any] else { continue }
                    let secs = TimeInterval(w["limit_window_seconds"] as? Double ?? 18000)
                    let label: String
                    let wid: String
                    switch secs {
                    case ..<(24 * 3600): label = "\(Int(secs / 3600)) h"; wid = "5h"
                    case 7 * 86400: label = "Week"; wid = "week"
                    default: label = "\(Int(secs / 86400)) d"; wid = "long"
                    }
                    let resets = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    let pct = w["used_percent"] as? Double ?? 0
                    windows.append(UsageWindow(id: wid, label: label, percent: pct, resetsAt: resets,
                                               length: secs, locked: reached && pct >= 100))
                }
            }
            return ServiceUsage(id: id, name: name, plan: plan, windows: windows, error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "run codex once"))
        }
    }

    // MARK: - OpenCode Go

    static func opencodeGo() async -> ServiceUsage {
        let id = "opencode", name = "OpenCode Go"
        guard let key = keychain(service: "opencode-go-api-key")
        else { return .failed(id, name, "No API key in Keychain (opencode-go-api-key)") }

        do {
            let j = try await get("https://opencode.ai/zen/go/v1/usage", headers: [
                "Authorization": "Bearer \(key)",
                "User-Agent": "ai-usage-widget/1.0",
            ])
            guard let u = j["usage"] as? [String: Any] else { throw ProviderError.parse }
            let spec: [(key: String, id: String, label: String, length: TimeInterval)] = [
                ("rolling", "5h", "5 h", 5 * 3600),
                ("weekly", "week", "Week", 7 * 86400),
                ("monthly", "month", "Month", 30 * 86400),
            ]
            var windows: [UsageWindow] = []
            for s in spec {
                guard let w = u[s.key] as? [String: Any] else { continue }
                windows.append(UsageWindow(id: s.id, label: s.label,
                                           percent: w["percent"] as? Double ?? 0,
                                           resetsAt: date(w["resetsAt"]), length: s.length,
                                           locked: (w["status"] as? String) == "rate-limited"))
            }
            return ServiceUsage(id: id, name: name, plan: "Go", windows: windows, error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "check the API key"))
        }
    }

    static func fetchAll() async -> [ServiceUsage] {
        async let a = claude()
        async let b = codex()
        async let c = opencodeGo()
        return await [a, b, c]
    }
}
