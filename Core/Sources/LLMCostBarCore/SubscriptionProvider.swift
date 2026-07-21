import Foundation

/// Parallel to VendorProvider but deliberately separate: subscription sources
/// have no accounts row and no per-account Keychain credential, so routing them
/// through the account/credential machinery would poison the reauth paths.
public protocol SubscriptionProvider: Sendable {
    var sourceID: String { get }
    /// Cheap, prompt-free check run every poll; undetected sources are skipped silently.
    func isDetected() -> Bool
    /// Point-in-time window utilization. Throws ProviderError; .auth means the
    /// borrowed CLI credential is unusable (stale + reason), never needs_reauth.
    func fetchSnapshot(now: Date) async throws -> SubscriptionSnapshot
}

/// Claude Pro/Max limits via Claude Code's OAuth token — the same endpoint and
/// headers Claude Code's /usage uses. (Approach borrowed from steipete/CodexBar, MIT.)
public struct ClaudeSubscriptionProvider: SubscriptionProvider {
    public let sourceID = SubscriptionSource.claude
    let http: any HTTPClient
    let base: URL
    /// Non-interactive by construction in the daemon (ClaudeTokenResolver):
    /// this provider can therefore never trigger a keychain prompt.
    let credentials: any ClaudeCredentialSource
    let detect: @Sendable () -> Bool

    public init(http: any HTTPClient = URLSessionHTTPClient(),
                base: URL = URL(string: "https://api.anthropic.com")!,
                credentials: any ClaudeCredentialSource = ClaudeTokenResolver.live(),
                detect: @escaping @Sendable () -> Bool = { ClaudeCodeCredentials.isDetected() }) {
        self.http = http; self.base = base; self.credentials = credentials; self.detect = detect
    }

    public func isDetected() -> Bool { detect() }

    public func fetchSnapshot(now: Date) async throws -> SubscriptionSnapshot {
        let resolved: ResolvedClaudeToken
        switch credentials.resolve() {
        case .found(let t): resolved = t
        case .signedOut: throw ProviderError.auth(0, "sign in to Claude Code first")
        case .reconnectNeeded: throw ProviderError.auth(0, ClaudeTokenResolver.reconnectReason)
        case .invalid(let reason): throw ProviderError.decode(reason)
        }
        var token = resolved
        var (data, status) = try await usageRequest(token: token.accessToken)
        if status == 401 {
            // Claude Code may have rotated the token under our cache — give the
            // source ONE chance to hand back a replacement (silent recovery);
            // otherwise surface its stale reason. Never loops.
            let (retry, reason) = credentials.after401(failedToken: token.accessToken,
                                                       source: token.source)
            guard let retry else { throw ProviderError.auth(401, reason) }
            token = retry
            (data, status) = try await usageRequest(token: token.accessToken)
            if status == 401 {
                let (_, reason) = credentials.after401(failedToken: token.accessToken,
                                                       source: token.source)
                throw ProviderError.auth(401, reason)
            }
        }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        return try Self.parse(data, planType: token.subscriptionType, now: now)
    }

    private func usageRequest(token: String) async throws -> (Data, Int) {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            // Load-bearing: without a claude-code UA this endpoint rate-limits aggressively.
            "User-Agent": "claude-code/2.0.0",
        ]
        return try await http.get(base.appendingPathComponent("api/oauth/usage"), headers: headers)
    }

    static let windowIDs = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    static func parse(_ data: Data, planType: String?, now: Date) throws -> SubscriptionSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("oauth/usage: not a JSON object")
        }
        var windows: [SubscriptionWindow] = []
        for id in windowIDs {
            // null / absent windows (e.g. seven_day_opus on Pro) are simply skipped
            guard let w = obj[id] as? [String: Any],
                  let pct = SubJSON.double(w["utilization"]) else { continue }
            windows.append(SubscriptionWindow(windowID: id, usedPercent: pct,
                                              resetsAt: SubJSON.date(w["resets_at"])))
        }
        guard !windows.isEmpty else { throw ProviderError.decode("oauth/usage: no usage windows in response") }
        return SubscriptionSnapshot(source: SubscriptionSource.claude, planType: planType,
                                    observedAt: now, origin: "api", windows: windows)
    }
}

/// Codex/ChatGPT rate-limit windows. Live backend call when auth.json exists;
/// otherwise (or on any API failure) the newest rate_limits event from local
/// session files, clearly origin-tagged so the UI can show its age.
public struct CodexSubscriptionProvider: SubscriptionProvider {
    public let sourceID = SubscriptionSource.codex
    let http: any HTTPClient
    let base: URL
    let home: URL

    public init(http: any HTTPClient = URLSessionHTTPClient(),
                base: URL = URL(string: "https://chatgpt.com/backend-api")!,
                home: URL = CodexLocalState.defaultHome) {
        self.http = http; self.base = base; self.home = home
    }

    public func isDetected() -> Bool { CodexLocalState.isDetected(home: home) }

    public func fetchSnapshot(now: Date) async throws -> SubscriptionSnapshot {
        var apiError: ProviderError?
        if let auth = CodexLocalState.readAuth(home: home) {
            do { return try await fetchFromAPI(auth: auth, now: now) }
            catch let e as ProviderError { apiError = e }
            catch { apiError = .transient(String(describing: error).prefix(300).description) }
        }
        if let snap = CodexLocalState.latestRateLimits(home: home, now: now) { return snap }
        // No fallback data: surface the API failure (auth reason matters), else transient.
        throw apiError ?? ProviderError.transient("no codex session data yet — run Codex once")
    }

    func fetchFromAPI(auth: CodexAuth, now: Date) async throws -> SubscriptionSnapshot {
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "User-Agent": "LLMCostBar",
        ]
        if let id = auth.accountID { headers["ChatGPT-Account-Id"] = id }
        let (data, status) = try await http.get(base.appendingPathComponent("wham/usage"),
                                                headers: headers)
        if status == 401 { throw ProviderError.auth(401, "open Codex CLI to refresh sign-in") }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        return try Self.parseAPI(data, now: now)
    }

    /// The endpoint is undocumented; accept every shape seen in the wild:
    /// top-level {primary,secondary}, nested rate_limits{...}, or
    /// rate_limit{primary_window, secondary_window}.
    static func parseAPI(_ data: Data, now: Date) throws -> SubscriptionSnapshot {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("wham/usage: not a JSON object")
        }
        let container = (obj["rate_limits"] as? [String: Any])
            ?? (obj["rate_limit"] as? [String: Any]) ?? obj
        let windows = CodexLocalState.parseWindows(
            container: container,
            keys: [("primary", ["primary", "primary_window"]),
                   ("secondary", ["secondary", "secondary_window"])])
        guard !windows.isEmpty else { throw ProviderError.decode("wham/usage: no rate-limit windows in response") }
        let plan = (obj["plan_type"] as? String) ?? (container["plan_type"] as? String)
        return SubscriptionSnapshot(source: SubscriptionSource.codex, planType: plan,
                                    observedAt: now, origin: "api", windows: windows)
    }
}
