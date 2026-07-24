import Foundation

// MARK: - Vault-backed claude.ai web session

/// The user's claude.ai browser cookie plus the org id it resolves to.
/// Stored JSON-encoded in OUR keychain vault — never UserDefaults, config, or
/// logs — so daemon reads can never prompt (the vault item is ACL'd to both
/// binaries). Cookie approach from Artzainnn/ClaudeUsageBar (MIT); storage
/// hardened from their UserDefaults to Keychain.
public struct ClaudeWebSession: Codable, Equatable, Sendable {
    public var cookie: String
    public var orgID: String?

    public static let vaultKey = "__claude_web_session__"
    /// Machine-checked by the app (surfaces the re-paste UI) AND shown raw in
    /// Settings — keep it human-readable.
    public static let cookieExpiredReason =
        "claude.ai cookie expired — copy a fresh one from claude.ai and re-paste it in Settings"

    public init(cookie: String, orgID: String? = nil) {
        self.cookie = Self.normalize(cookie)
        self.orgID = orgID
    }

    /// Accept both a full Cookie header and a bare sessionKey value (users
    /// paste either; a bare value has no '=' pairs).
    public static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("=") ? t : "sessionKey=\(t)"
    }

    /// `lastActiveOrg=<uuid>` straight from the cookie — saves the bootstrap call.
    public static func orgID(fromCookie cookie: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("lastActiveOrg=") {
                let v = String(p.dropFirst("lastActiveOrg=".count))
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    // MARK: vault codec (the vault stores strings)

    public var encodedJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }

    public static func decode(_ json: String) -> ClaudeWebSession? {
        try? JSONDecoder().decode(ClaudeWebSession.self, from: Data(json.utf8))
    }
}

// MARK: - claude.ai internal web API

/// Reader for the claude.ai web app's own endpoints, authenticated by the
/// session cookie. Header set mirrors what the browser sends (proven to work
/// from URLSession by ClaudeUsageBar): full cookie + browser UA + same-origin
/// markers. All parsers are pure statics, testable on fixtures.
public struct ClaudeWebClient: Sendable {
    let http: any HTTPClient
    let base: URL

    public init(http: any HTTPClient, base: URL = URL(string: "https://claude.ai")!) {
        self.http = http
        self.base = base
    }

    static func headers(cookie: String) -> [String: String] {
        [
            "Cookie": cookie,
            "Accept": "*/*",
            "Content-Type": "application/json",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
        ]
    }

    func get(_ path: String, cookie: String) async throws -> (Data, Int) {
        try await http.get(base.appendingPathComponent(path),
                           headers: Self.headers(cookie: cookie))
    }

    /// 401 and 403 both mean the cookie no longer authenticates — one uniform,
    /// actionable reason (there is no refresh flow for a browser cookie).
    static func authError(_ status: Int) -> ProviderError? {
        (status == 401 || status == 403)
            ? .auth(status, ClaudeWebSession.cookieExpiredReason) : nil
    }

    // MARK: org id

    public func fetchOrgID(cookie: String) async throws -> String {
        let (data, status) = try await get("api/bootstrap", cookie: cookie)
        if let err = Self.authError(status) { throw err }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        guard let org = Self.parseBootstrapOrgID(data) else {
            throw ProviderError.decode("claude.ai bootstrap: no account.lastActiveOrgId")
        }
        return org
    }

    public static func parseBootstrapOrgID(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["account"] as? [String: Any],
              let org = account["lastActiveOrgId"] as? String, !org.isEmpty else { return nil }
        return org
    }

    // MARK: usage windows

    public func fetchUsageWindows(cookie: String, orgID: String) async throws -> [SubscriptionWindow] {
        let (data, status) = try await get("api/organizations/\(orgID)/usage", cookie: cookie)
        if let err = Self.authError(status) { throw err }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        return try Self.parseUsage(data)
    }

    public static func parseUsage(_ data: Data) throws -> [SubscriptionWindow] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decode("claude.ai usage: not a JSON object")
        }
        var windows: [SubscriptionWindow] = []
        for id in ClaudeSubscriptionProvider.windowIDs {
            guard let w = obj[id] as? [String: Any],
                  let pct = SubJSON.double(w["utilization"]) else { continue }
            windows.append(SubscriptionWindow(windowID: id, usedPercent: pct,
                                              resetsAt: SubJSON.date(w["resets_at"])))
        }
        // Newer, separately-counted models (e.g. Fable) are not top-level keys —
        // they live in `limits` as model-scoped weekly entries.
        for entry in (obj["limits"] as? [[String: Any]]) ?? [] {
            guard let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty,
                  let pct = SubJSON.double(entry["percent"]) else { continue }
            let id = "seven_day_" + name.lowercased().replacingOccurrences(of: " ", with: "_")
            guard !windows.contains(where: { $0.windowID == id }) else { continue }
            windows.append(SubscriptionWindow(windowID: id, usedPercent: pct,
                                              resetsAt: SubJSON.date(entry["resets_at"])))
        }
        guard !windows.isEmpty else {
            throw ProviderError.decode("claude.ai usage: no usage windows in response")
        }
        return windows
    }

    // MARK: extra-usage spend + prepaid credits

    /// Both money endpoints in one call. Throws only when NEITHER endpoint
    /// yields data — the caller treats credit info as additive (its failure
    /// must never take down the usage bars).
    public func fetchCredit(cookie: String, orgID: String) async throws -> SubscriptionCredit {
        var credit = SubscriptionCredit(spentMinor: 0, limitMinor: 0, currency: "USD",
                                        resetsAt: nil, freeCreditsMinor: 0)
        var sawAny = false
        if let (data, status) = try? await get("api/organizations/\(orgID)/overage_spend_limit",
                                               cookie: cookie),
           status == 200, let o = Self.parseOverage(data) {
            credit.spentMinor = o.spentMinor
            credit.limitMinor = o.limitMinor
            credit.currency = o.currency
            credit.resetsAt = o.resetsAt
            sawAny = true
        }
        if let (data, status) = try? await get("api/organizations/\(orgID)/prepaid/credits",
                                               cookie: cookie),
           status == 200, let p = Self.parseCredits(data) {
            credit.freeCreditsMinor = p.freeMinor
            if let c = p.currency { credit.currency = c }
            sawAny = true
        }
        guard sawAny else { throw ProviderError.decode("claude.ai: no credit data") }
        return credit
    }

    public static func parseOverage(_ data: Data)
    -> (spentMinor: Int, limitMinor: Int, currency: String, resetsAt: Date?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (spentMinor: SubJSON.int(obj["used_credits"]) ?? 0,
                limitMinor: SubJSON.int(obj["monthly_credit_limit"]) ?? 0,
                currency: (obj["currency"] as? String) ?? "USD",
                resetsAt: SubJSON.date(obj["disabled_until"]))
    }

    public static func parseCredits(_ data: Data) -> (freeMinor: Int, currency: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // `amount` is the current balance; fall back to summing remaining tranches.
        var free = SubJSON.int(obj["amount"])
        if free == nil {
            var remaining = 0
            var sawTranche = false
            for key in ["tranches", "promo_tranches"] {
                for t in (obj[key] as? [[String: Any]]) ?? [] {
                    remaining += SubJSON.int(t["remaining_amount_minor_units"]) ?? 0
                    sawTranche = true
                }
            }
            free = sawTranche ? remaining : nil
        }
        guard let free else { return nil }
        return (freeMinor: free, currency: obj["currency"] as? String)
    }
}
