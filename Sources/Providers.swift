import Foundation
import SQLite3
import CommonCrypto

enum ProviderError: Error {
    case http(Int)
    case parse
    case cursorCredential(String)
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

    /// Cursor stores its session JWT in the IDE's `state.vscdb` (VS Code-style key/value SQLite).
    /// Read-only so a running Cursor doesn't get blocked; never written by this app.
    static func cursorStateValue(_ key: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        var s = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
        // VS Code sometimes persists strings as JSON-quoted values.
        if s.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(s.utf8)) {
            s = decoded
        }
        return s.isEmpty ? nil : s
    }

    /// Newer Cursor versions store an Electron Safe Storage envelope in state.vscdb.
    /// Decode only the access token; never modify Cursor's database or persist plaintext.
    static func cursorAccessToken() throws -> String? {
        guard let stored = cursorStateValue("cursorAuth/accessToken") else { return nil }
        guard stored.hasPrefix("cursor-safe-storage:") else { return stored }
        let prefix = "cursor-safe-storage:v1:"
        guard stored.hasPrefix(prefix),
              let encrypted = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
              encrypted.starts(with: Data("v10".utf8)) else {
            throw ProviderError.cursorCredential("Unsupported Cursor login format — update AI Usage")
        }
        guard let password = keychain(service: "Cursor Safe Storage") else {
            throw ProviderError.cursorCredential("Allow access to Cursor Safe Storage in Keychain, then refresh")
        }
        guard let token = decryptCursorToken(encrypted, password: password), !token.isEmpty else {
            throw ProviderError.cursorCredential("Could not read the encrypted Cursor login — open Cursor and refresh")
        }
        return token
    }

    /// Chromium macOS Safe Storage v10: PBKDF2-SHA1 and AES-128-CBC with PKCS7 padding.
    static func decryptCursorToken(_ encrypted: Data, password: String) -> String? {
        guard encrypted.starts(with: Data("v10".utf8)) else { return nil }
        let ciphertext = Data(encrypted.dropFirst(3))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }
        let passwordBytes = Array(password.utf8)
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derived = passwordBytes.withUnsafeBytes { pass in
            salt.withUnsafeBufferPointer { saltBytes in
                key.withUnsafeMutableBufferPointer { keyBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress?.assumingMemoryBound(to: Int8.self), passwordBytes.count,
                        saltBytes.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003, keyBytes.baseAddress, keyBytes.count)
                }
            }
        }
        guard derived == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                ciphertext.withUnsafeBytes { input in
                    plaintext.withUnsafeMutableBytes { output in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress, input.baseAddress, ciphertext.count,
                            output.baseAddress, output.count, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(bytes: plaintext.prefix(written), encoding: .utf8)
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

    static func post(_ url: String, headers: [String: String], body: String = "{}") async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = Data(body.utf8)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ProviderError.http(code) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.parse
        }
        return json
    }

    /// Cursor billing-cycle timestamps arrive as unix-ms strings (or numbers).
    static func cursorMs(_ v: Any?) -> Date? {
        if let s = v as? String, let n = Double(s) {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = v as? Double {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let n = v as? Int {
            let d = Double(n)
            return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
        }
        return date(v)
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
        if case ProviderError.cursorCredential(let message) = error { return message }
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

    // MARK: - Cursor

    static func cursor() async -> ServiceUsage {
        let id = "cursor", name = "Cursor"
        let token: String
        do {
            guard let value = try cursorAccessToken() else { return .failed(id, name, "No Cursor login found") }
            token = value
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Cursor once"))
        }

        let plan = cursorStateValue("cursorAuth/stripeMembershipType").map { $0.capitalized }

        do {
            let j = try await post(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                ])
            guard let pu = j["planUsage"] as? [String: Any] else { throw ProviderError.parse }
            let start = cursorMs(j["billingCycleStart"])
            let end = cursorMs(j["billingCycleEnd"])
            let length: TimeInterval = {
                if let start, let end { return max(end.timeIntervalSince(start), 86400) }
                return 30 * 86400
            }()
            let pct = pu["totalPercentUsed"] as? Double ?? 0
            let windows = [
                UsageWindow(id: "month", label: "Month", percent: pct, resetsAt: end,
                            length: length, locked: pct >= 100),
            ]
            return ServiceUsage(id: id, name: name, plan: plan, windows: windows, error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Cursor once"))
        }
    }

    // MARK: - Grok Bot (the separate allowance on a Cursor account)

    static func grokBot() async -> ServiceUsage {
        let id = "grokbot", name = "Grok Bot"
        let token: String
        do {
            guard let value = try cursorAccessToken() else {
                return .failed(id, name, "No Cursor login found — sign in to the linked Cursor account")
            }
            token = value
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Cursor once"))
        }

        do {
            // This is the same DashboardService query the Grok Bot desktop app uses.
            let j = try await post(
                "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                ])
            if j["usesPooledEnterpriseAllowance"] as? Bool == true {
                return .failed(id, name, "Shared team allowance — no individual percentage reported")
            }
            guard let pct = j["usagePercent"] as? Double, pct.isFinite, pct >= 0 else {
                throw ProviderError.parse
            }
            let start = date(j["currentPeriodStart"])
            let end = date(j["nextResetTimestampUtc"])
            let length: TimeInterval
            if let start, let end, end > start {
                length = end.timeIntervalSince(start)
            } else {
                length = 7 * 86400
            }
            let window = UsageWindow(id: "week", label: "Week", percent: pct,
                                     resetsAt: end, length: length,
                                     locked: pct >= 100 || j["hasAvailableUsage"] as? Bool == false)
            return ServiceUsage(id: id, name: name, plan: j["grokPlanLabel"] as? String,
                                windows: [window], error: nil, fetchedAt: Date())
        } catch {
            return .failed(id, name, describe(error, loginHint: "open Cursor and check the linked account"))
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
        async let c = cursor()
        async let d = grokBot()
        async let e = opencodeGo()
        return await [a, b, c, d, e]
    }
}
