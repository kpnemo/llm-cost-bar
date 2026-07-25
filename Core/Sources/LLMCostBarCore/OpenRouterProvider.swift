import Foundation

public struct OpenRouterProvider: VendorProvider {
    public let vendorID = "openrouter"
    let accountID: String
    let credential: Credential
    let http: HTTPClient
    let baseURL: URL

    public init(accountID: String, credential: Credential, http: HTTPClient = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!) {
        self.accountID = accountID; self.credential = credential; self.http = http; self.baseURL = baseURL
    }

    // MARK: response shapes (tolerant: unknown fields ignored by Codable)
    private struct CreditsResp: Decodable {
        struct D: Decodable { let total_credits: Double; let total_usage: Double }
        let data: D
    }
    private struct ActivityResp: Decodable {
        struct Row: Decodable {
            let date: String
            let model: String
            let usage: Double
            let requests: Int?
            let prompt_tokens: Int?
            let completion_tokens: Int?
        }
        let data: [Row]
    }
    private struct KeysListResp: Decodable {
        struct K: Decodable {
            let name: String?
            let label: String?
            let hash: String?
            let usage: Double?
            let usage_daily: Double?     // live, current UTC day — /activity only has completed days
            let usage_monthly: Double?   // live, current UTC month
            let limit: Double?
            let limit_remaining: Double?
            let limit_reset: String?
            let disabled: Bool?
        }
        let data: [K]
    }
    private struct KeyResp: Decodable {
        struct D: Decodable { let label: String? }
        let data: D
    }

    // Query items go through URLComponents: appendingPathComponent would
    // percent-encode a "?" embedded in the path, breaking the real API.
    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = [],
                                       as type: T.Type) async throws -> T {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        let url = comps.url!
        let (data, status): (Data, Int)
        do { (data, status) = try await http.get(url, bearer: credential.apiKey) }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.transient(String(describing: error)) }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            let snippet = (String(data: data, encoding: .utf8) ?? "<binary>").prefix(300)
            throw ProviderError.decode("decoding \(path): \(error) — body: \(snippet)")
        }
    }

    public func validateCredentials() async throws -> AccountInfo {
        let resp = try await getJSON("key", as: KeyResp.self)
        return AccountInfo(label: resp.data.label ?? "openrouter-key")
    }

    public func fetchBalance() async throws -> Balance? {
        let resp = try await getJSON("credits", as: CreditsResp.self)
        return Balance(balanceUSD: resp.data.total_credits - resp.data.total_usage,
                       totalCreditsUSD: resp.data.total_credits,
                       totalUsageUSD: resp.data.total_usage)
    }

    /// Real per-key dollars: /keys supplies name + hash + live usage_daily/
    /// usage_monthly + budget limits, then one /activity?api_key_hash= call
    /// per key returns its daily usage for the 30d column. Keys without a
    /// hash (or with zero spend in every window) drop out; display name falls
    /// back name → label → "unnamed". Requires a management key, same as the
    /// pooled /activity call.
    ///
    /// This is N+1 serial GETs (one /keys call, then one /activity call per
    /// key), and the whole thing is retried wholesale by SyncEngine's
    /// withRetry on any transient failure. Fine at today's key counts; if a
    /// workspace's key count grows past ~20, revisit with a TaskGroup for
    /// concurrent fetches or per-key retry tolerance so one flaky key doesn't
    /// re-fetch everyone else's activity.
    public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal] {
        let keys = try await getJSON("keys", as: KeysListResp.self).data
        let today = Day.utcToday(now: now)
        let monthStart = Day.utcMonthPrefix(now: now) + "-01"
        let windowStart = Day.last30Start(now: now)
        var rows: [KeyTotal] = []
        for key in keys {
            guard let hash = key.hash else { continue }
            // Identity is the hash (stable across renames); the display name is
            // re-read every sync, so a rename simply relabels the row next poll.
            let name = key.name ?? key.label ?? "unnamed"
            let resp = try await getJSON("activity",
                                         query: [.init(name: "api_key_hash", value: hash)],
                                         as: ActivityResp.self)
            var windowBeforeToday = 0.0, preMonthWindow = 0.0
            var activityMTDBeforeToday = 0.0, activityToday = 0.0
            for row in resp.data where row.usage != 0 {
                let day = String(row.date.prefix(10))
                if day >= windowStart && day < today { windowBeforeToday += row.usage }
                if day >= windowStart && day < monthStart { preMonthWindow += row.usage }
                if day >= monthStart && day < today { activityMTDBeforeToday += row.usage }
                if day == today { activityToday += row.usage }
            }
            // /activity only covers COMPLETED UTC days (with up to ~24h publish
            // lag), so today/MTD prefer the key's live usage_daily/usage_monthly
            // counters (credits-consistent, real-time); the activity sums remain
            // as fallback for older shapes.
            let todayUSD = key.usage_daily ?? activityToday
            let mtdUSD = key.usage_monthly ?? (activityMTDBeforeToday + todayUSD)
            // 30d: the whole in-month portion rides the SAME live counter as
            // MTD (pre-month activity + mtd), so MTD ≤ 30d holds even while
            // /activity lags a just-completed in-month day (issue #3). Only on
            // day ≥ 31 of a month (monthStart before the window) does the
            // window fall back to activity-before-today + live today — there
            // MTD > 30d is legitimate (day 1 is outside the window).
            let totalUSD = monthStart >= windowStart ? preMonthWindow + mtdUSD
                                                     : windowBeforeToday + todayUSD
            rows.append(KeyTotal(apiKeyID: name, totalUSD: totalUSD, todayUSD: todayUSD, mtdUSD: mtdUSD,
                                 limitUSD: key.limit, limitRemainingUSD: key.limit_remaining,
                                 limitReset: key.limit_reset, disabled: key.disabled ?? false,
                                 lifetimeUSD: key.usage))
        }
        // Merge BEFORE the visibility filter so a zero-spend same-name sibling
        // still contributes lifetime/limit metadata to the surviving row. Keys
        // without a hash never get here (can't be fetched per-key); a merged
        // group with zero spend in every window stays hidden by design.
        return KeyTotal.mergedByName(rows).filter {
            $0.totalUSD > 0 || ($0.todayUSD ?? 0) > 0 || ($0.mtdUSD ?? 0) > 0
        }
    }

    public func fetchUsage(sinceDaysAgo: Int, now: Date = Date()) async throws -> [UsageRecord] {
        // /activity returns the whole recent window; sinceDaysAgo filters client-side.
        let keyLabel = (try? await validateCredentials().label) ?? "default"
        let resp = try await getJSON("activity", as: ActivityResp.self)
        let cutoff = Day.utcToday(now: now.addingTimeInterval(-Double(sinceDaysAgo) * 86400))
        // /activity groups rows per ENDPOINT, so one model can span several rows
        // on the same day (different providers). The store upserts on
        // (model, day) — sum here, or colliding rows overwrite and drop spend.
        var order: [String] = []
        var merged: [String: UsageRecord] = [:]
        for row in resp.data where row.date >= cutoff {
            // Live API returns "2026-07-18 00:00:00"; normalize to the bare
            // day key the store's exact-match queries use.
            let day = String(row.date.prefix(10))
            let key = day + "|" + row.model
            if var r = merged[key] {
                r.requests += row.requests ?? 0
                r.tokensIn += row.prompt_tokens ?? 0
                r.tokensOut += row.completion_tokens ?? 0
                r.costUSD += row.usage
                merged[key] = r
            } else {
                order.append(key)
                merged[key] = UsageRecord(vendor: vendorID, accountID: accountID, apiKeyID: keyLabel,
                                          model: row.model, day: day,
                                          requests: row.requests ?? 0,
                                          tokensIn: row.prompt_tokens ?? 0, tokensOut: row.completion_tokens ?? 0,
                                          costUSD: row.usage)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
