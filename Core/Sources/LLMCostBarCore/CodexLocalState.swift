import Foundation

public struct CodexAuth: Equatable, Sendable {
    public var accessToken: String
    public var accountID: String?
    public init(accessToken: String, accountID: String?) {
        self.accessToken = accessToken; self.accountID = accountID
    }
}

/// Reads Codex CLI's on-disk state: auth.json (plaintext OAuth tokens, mode 0600)
/// and session rollout files carrying rate_limits events. Read-only — token
/// refresh stays Codex's job. All entry points take `home` so tests use temp dirs.
public enum CodexLocalState {
    public static var defaultHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public static func isDetected(home: URL = defaultHome) -> Bool {
        FileManager.default.fileExists(atPath: home.path)
    }

    /// nil = auth.json absent (Codex keyring storage mode) or unparseable —
    /// callers fall back to session-file snapshots.
    public static func readAuth(home: URL = defaultHome) -> CodexAuth? {
        (try? Data(contentsOf: home.appendingPathComponent("auth.json"))).flatMap(parseAuth)
    }

    public static func parseAuth(_ data: Data) -> CodexAuth? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = (obj["tokens"] as? [String: Any]) ?? obj
        guard let token = (tokens["access_token"] ?? tokens["accessToken"]) as? String,
              !token.isEmpty else { return nil }
        return CodexAuth(accessToken: token,
                         accountID: (tokens["account_id"] ?? tokens["accountId"]) as? String)
    }

    // MARK: session-file rate_limits fallback

    /// Newest rate_limits event across recent rollout files. Bounded scan:
    /// day dirs walked newest-first up to `maxDays` back, files by mtime,
    /// only the tail of each file is read.
    public static func latestRateLimits(home: URL = defaultHome, now: Date = Date(),
                                        maxDays: Int = 7, maxFiles: Int = 10) -> SubscriptionSnapshot? {
        let fm = FileManager.default
        let sessions = home.appendingPathComponent("sessions")
        let cal = Calendar(identifier: .gregorian)
        var candidates: [(url: URL, mtime: Date)] = []
        for back in 0...maxDays {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: day)
            let dir = sessions
                .appendingPathComponent(String(format: "%04d", c.year!))
                .appendingPathComponent(String(format: "%02d", c.month!))
                .appendingPathComponent(String(format: "%02d", c.day!))
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                candidates.append((f, mtime))
            }
        }
        for (url, mtime) in candidates.sorted(by: { $0.mtime > $1.mtime }).prefix(maxFiles) {
            if let snap = latestRateLimits(inFile: url, fallbackDate: mtime) { return snap }
        }
        return nil
    }

    static func latestRateLimits(inFile url: URL, fallbackDate: Date) -> SubscriptionSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("rate_limits") {
            if let snap = snapshot(fromLine: String(line), fallbackDate: fallbackDate) { return snap }
        }
        return nil
    }

    static func snapshot(fromLine line: String, fallbackDate: Date) -> SubscriptionSnapshot? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let rl = SubJSON.findDict(in: obj, key: "rate_limits") else { return nil }
        let windows = parseWindows(container: rl,
                                   keys: [("primary", ["primary"]), ("secondary", ["secondary"])])
        guard !windows.isEmpty else { return nil }
        let observed = SubJSON.date((obj as? [String: Any])?["timestamp"]) ?? fallbackDate
        return SubscriptionSnapshot(source: SubscriptionSource.codex,
                                    planType: rl["plan_type"] as? String,
                                    observedAt: observed, origin: "jsonl", windows: windows)
    }

    /// Shared by the JSONL and live-API paths: field names differ per source
    /// (window_minutes vs limit_window_seconds, resets_at vs reset_at).
    static func parseWindows(container: [String: Any],
                             keys: [(id: String, aliases: [String])]) -> [SubscriptionWindow] {
        var out: [SubscriptionWindow] = []
        for (id, aliases) in keys {
            for alias in aliases {
                guard let w = container[alias] as? [String: Any],
                      let pct = SubJSON.double(w["used_percent"]) else { continue }
                let minutes = SubJSON.int(w["window_minutes"])
                    ?? SubJSON.int(w["limit_window_seconds"]).map { $0 / 60 }
                let resets = SubJSON.date(w["resets_at"] ?? w["reset_at"])
                out.append(SubscriptionWindow(windowID: id, usedPercent: pct,
                                              resetsAt: resets, windowMinutes: minutes))
                break
            }
        }
        return out
    }
}
