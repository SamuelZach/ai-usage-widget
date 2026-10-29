import Foundation

enum ProviderError: Error {
    case http(Int)
    case parse
}

enum Providers {
    // MARK: - Helpers

    /// Reads one generic password via the `security` CLI. Going through the CLI means the
    /// existing keychain ACLs (already granted to `security`) keep working without prompts.
    /// Pass `account` when the item is identified by both service and account.
    static func keychain(service: String, account: String? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-s", service]
        if let account { args += ["-a", account] }
        args.append("-w")
        p.arguments = args
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

    static func get(_ url: String, headers: [String: String], method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 15
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
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

    /// Cursor's dashboard returns unix milliseconds, sometimes as a string.
    static func epoch(_ v: Any?) -> Date? {
        if let s = v as? String {
            if let n = Double(s) { return epoch(n) }
            return date(s)
        }
        if let n = v as? NSNumber { return epoch(n.doubleValue) }
        return nil
    }

    private static func epoch(_ n: Double) -> Date? {
        if n > 1e12 { return Date(timeIntervalSince1970: n / 1000) }
        if n > 1e9 { return Date(timeIntervalSince1970: n) }
        return nil
    }

    static func double(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    /// One value from Cursor's state DB. Read-only; the token itself is never stored by this app.
    static func cursorState(_ key: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", path.path, "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;"]
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

    // MARK: - Cursor login

    private static let tokenLock = NSLock()
    private static var cachedCursorRaw: String?
    private static var cachedCursorPlain: String?
    private static let safeStoragePrefix = "cursor-safe-storage:v1:"

    /// Session token Cursor already has on this Mac. Newer Cursor builds store it encrypted
    /// (`cursor-safe-storage:v1:`). The plaintext is used for one request and never written down.
    static func cursorAccessToken() -> String? {
        guard let raw = cursorState("cursorAuth/accessToken") ?? keychain(service: "cursor-access-token"),
              !raw.isEmpty
        else { return nil }
        tokenLock.lock()
        if cachedCursorRaw == raw, let plain = cachedCursorPlain {
            tokenLock.unlock()
            return plain
        }
        tokenLock.unlock()

        let plain: String?
        if raw.hasPrefix(safeStoragePrefix) {
            plain = decryptCursorSafeStorage(raw)
        } else if raw.hasPrefix("cursor-safe-") {
            plain = nil
        } else {
            plain = raw
        }
        guard let plain, !plain.isEmpty else { return nil }
        tokenLock.lock()
        cachedCursorRaw = raw
        cachedCursorPlain = plain
        tokenLock.unlock()
        return plain
    }

    static func cursorLoginFailure() -> String {
        if cursorState("cursorAuth/accessToken")?.hasPrefix("cursor-safe-") == true {
            return "Allow Keychain access to “Cursor Safe Storage”"
        }
        return "No Cursor login found"
    }

    /// Electron safeStorage on macOS: Keychain password, PBKDF2-SHA1, AES-128-CBC, `v10` prefix.
    static func decryptCursorSafeStorage(_ raw: String) -> String? {
        guard raw.hasPrefix(safeStoragePrefix),
              let blob = Data(base64Encoded: String(raw.dropFirst(safeStoragePrefix.count))),
              blob.count > 3,
              blob.prefix(3) == Data("v10".utf8),
              let password = keychain(service: "Cursor Safe Storage", account: "Cursor Key")
        else { return nil }

        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: Int(kCCKeySizeAES128))
        let derived: CCStatus = password.withCString { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw, strlen(pw),
                salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key, key.count)
        }
        guard derived == kCCSuccess else { return nil }
        defer { for i in key.indices { key[i] = 0 } }

        let cipher = [UInt8](blob.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: Int(kCCBlockSizeAES128))
        var out = [UInt8](repeating: 0, count: cipher.count + Int(kCCBlockSizeAES128))
        var moved: size_t = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            cipher, cipher.count,
            &out, out.count,
            &moved)
        guard status == kCCSuccess, moved > 0 else { return nil }
        return String(bytes: out.prefix(moved), encoding: .utf8)
    }

    static func periodLabel(_ length: TimeInterval) -> (id: String, label: String) {
        switch length {
        case ..<(36 * 3600): return ("short", "\(max(1, Int(length / 3600))) h")
        case ..<(8 * 86400): return ("week", "Week")
        default: return ("month", "Month")
        }
    }

    // MARK: - Cursor

    static func cursor() async -> ServiceUsage {
        let id = "cursor", name = "Cursor"
        // Cursor refreshes this session token itself. Same rule as Claude and Codex:
        // read it, never store it, and ask the user to open the app if it has expired.
        guard let token = cursorAccessToken() else { return .failed(id, name, cursorLoginFailure()) }

        let localPlan = cursorState("cursorAuth/stripeMembershipType").map(prettyPlan)
        let headers = [
            "Authorization": "Bearer \(token)",
            "Connect-Protocol-Version": "1",
        ]
        do {
            let j = try await get(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                headers: headers, method: "POST", body: Data("{}".utf8))
            guard let planUsage = j["planUsage"] as? [String: Any] else { throw ProviderError.parse }

            let start = epoch(j["billingCycleStart"])
            let end = epoch(j["billingCycleEnd"])
            let length: TimeInterval = {
                if let start, let end, end > start { return end.timeIntervalSince(start) }
                return 30 * 86400
            }()
            let percent: Double = {
                if let p = double(planUsage["totalPercentUsed"]) { return p }
                let limit = double(planUsage["limit"]) ?? 0
                let used = double(planUsage["includedSpend"]) ?? 0
                return limit > 0 ? used / limit * 100 : 0
            }()
            let (wid, label) = periodLabel(length)
            let window = UsageWindow(id: wid, label: label, percent: percent, resetsAt: end,
                                     length: length, locked: percent >= 100)

            var plan = localPlan
            if let info = try? await get(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo",
                headers: headers, method: "POST", body: Data("{}".utf8)),
               let planInfo = info["planInfo"] as? [String: Any],
               let planName = planInfo["planName"] as? String, !planName.isEmpty {
                plan = planName
            }
            return ServiceUsage(id: id, name: name, plan: plan, windows: [window], error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Cursor once"))
        }
    }

    // MARK: - Grok Bot

    /// Same Cursor login. Grok Bot's allowance is a separate pool (`GetSandUsageStatus`).
    static func grok() async -> ServiceUsage {
        let id = "grok", name = "Grok Bot"
        guard let token = cursorAccessToken() else { return .failed(id, name, cursorLoginFailure()) }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Connect-Protocol-Version": "1",
        ]
        do {
            let j = try await get(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
                headers: headers, method: "POST", body: Data("{}".utf8))
            if (j["usesPooledEnterpriseAllowance"] as? Bool) == true, double(j["usagePercent"]) == nil {
                return .failed(id, name, "Shared team allowance — no individual percentage reported")
            }
            guard let percent = double(j["usagePercent"]) else {
                return .failed(id, name, "No individual percentage reported")
            }
            let start = date(j["currentPeriodStart"]) ?? epoch(j["currentPeriodStart"])
            let end = date(j["nextResetTimestampUtc"]) ?? epoch(j["nextResetTimestampUtc"])
            let length: TimeInterval = {
                if let start, let end, end > start { return end.timeIntervalSince(start) }
                return 30 * 86400
            }()
            let (wid, label) = periodLabel(length)
            let plan = (j["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let window = UsageWindow(id: wid, label: label, percent: percent, resetsAt: end,
                                     length: length, locked: percent >= 100 || (j["hasAvailableUsage"] as? Bool) == false)
            return ServiceUsage(id: id, name: name, plan: plan, windows: [window], error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Cursor and check the linked account"))
        }
    }

    static func prettyPlan(_ raw: String) -> String {
        raw.split(separator: "_").map { part in
            guard let first = part.first else { return "" }
            return first.uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - OpenCode Go

    /// OpenCode writes the Go key into auth.json. The Keychain item is only a fallback;
    /// an empty or stale one makes the card report 0% while the real account still has usage.
    static func opencodeGoKey() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        if let data = try? Data(contentsOf: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = json["opencode-go"] as? [String: Any],
           let key = entry["key"] as? String, !key.isEmpty {
            return key
        }
        return keychain(service: "opencode-go-api-key")
    }

    static func opencodeGo() async -> ServiceUsage {
        let id = "opencode", name = "OpenCode Go"
        guard let key = opencodeGoKey()
        else { return .failed(id, name, "No OpenCode Go login (~/.local/share/opencode/auth.json)") }

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
                                           percent: double(w["percent"]) ?? 0,
                                           resetsAt: date(w["resetsAt"]), length: s.length,
                                           locked: (w["status"] as? String) == "rate-limited"))
            }
            if windows.isEmpty { throw ProviderError.parse }
            return ServiceUsage(id: id, name: name, plan: "Go", windows: windows, error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "check the API key"))
        }
    }

    static func fetchAll() async -> [ServiceUsage] {
        _ = cursorAccessToken()
        async let a = claude()
        async let b = codex()
        async let c = cursor()
        async let g = grok()
        async let d = opencodeGo()
        return await [a, b, c, g, d]
    }
}
