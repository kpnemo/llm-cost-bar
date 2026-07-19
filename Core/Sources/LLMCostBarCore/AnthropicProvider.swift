import Foundation

/// Anthropic vendor provider, backed by the Admin Usage & Cost API.
/// Requires an ADMIN API key (sk-ant-admin01-…) — regular API keys can't read
/// org-level reports. Cost data comes from /v1/organizations/cost_report
/// (daily buckets, USD amounts as decimal strings in cents, grouped by
/// description which carries the model). Anthropic has no prepaid balance
/// endpoint, so fetchBalance is nil. Per-key dollars are not exposed either
/// (cost_report only groups by workspace/description), so fetchKeyTotals
/// estimates them: each day's real cost per model is split across keys in
/// proportion to that day's price-weighted tokens from the usage report.
public struct AnthropicProvider: VendorProvider {
    public let vendorID = "anthropic"
    let accountID: String
    let credential: Credential
    let http: HTTPClient
    let baseURL: URL

    public init(accountID: String, credential: Credential, http: HTTPClient = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://api.anthropic.com")!) {
        self.accountID = accountID; self.credential = credential; self.http = http; self.baseURL = baseURL
    }

    private var headers: [String: String] {
        ["x-api-key": credential.apiKey, "anthropic-version": "2023-06-01"]
    }

    // MARK: response shapes (tolerant)
    private struct CostResp: Decodable {
        struct Bucket: Decodable {
            let starting_at: String
            let results: [Row]?
        }
        struct Row: Decodable {
            // Docs: "decimal strings in lowest units (cents)"; accept number too.
            let amount: AmountValue?
            let currency: String?
            let model: String?
            let description: String?
        }
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
    }

    /// amount arrives as "12345" (cents, string) per docs; be tolerant of numbers.
    enum AmountValue: Decodable {
        case string(String)
        case number(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .string(s); return }
            self = .number(try c.decode(Double.self))
        }
        var usd: Double {
            switch self {
            case .string(let s): (Double(s) ?? 0) / 100.0
            case .number(let n): n / 100.0
            }
        }
    }

    private func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, status): (Data, Int)
        do { (data, status) = try await http.get(url, headers: headers) }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.transient(String(describing: error)) }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            let snippet = (String(data: data, encoding: .utf8) ?? "<binary>").prefix(300)
            throw ProviderError.decode("decoding \(url.path): \(error) — body: \(snippet)")
        }
    }

    public func validateCredentials() async throws -> AccountInfo {
        _ = try await fetchUsage(sinceDaysAgo: 2, now: Date())
        return AccountInfo(label: "anthropic-admin")
    }

    public func fetchBalance() async throws -> Balance? { nil }

    // MARK: per-key spend (estimated)

    private struct UsageResp: Decodable {
        struct Bucket: Decodable { let starting_at: String; let results: [Row]? }
        struct CacheCreation: Decodable {
            let ephemeral_5m_input_tokens: Double?
            let ephemeral_1h_input_tokens: Double?
        }
        struct Row: Decodable {
            let api_key_id: String?
            let model: String?
            let uncached_input_tokens: Double?
            let cache_creation: CacheCreation?
            let cache_read_input_tokens: Double?
            let output_tokens: Double?
        }
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
    }

    private struct KeysListResp: Decodable {
        struct Key: Decodable { let id: String; let name: String? }
        let data: [Key]
        let has_more: Bool?
        let last_id: String?
    }

    /// Relative price ratios shared by current Claude models (output 5x input,
    /// cache read 0.1x, 5m cache write 1.25x, 1h cache write 2x). Only ratios
    /// matter — absolute prices come from cost_report, so there is no price
    /// table to keep in sync with model launches.
    private func weight(_ row: UsageResp.Row) -> Double {
        (row.uncached_input_tokens ?? 0)
            + 1.25 * (row.cache_creation?.ephemeral_5m_input_tokens ?? 0)
            + 2.0 * (row.cache_creation?.ephemeral_1h_input_tokens ?? 0)
            + 0.1 * (row.cache_read_input_tokens ?? 0)
            + 5.0 * (row.output_tokens ?? 0)
    }

    /// Usage models can carry a date suffix ("claude-sonnet-4-5-20250929")
    /// while cost_report's parsed model may not; compare with it stripped.
    static func normalizeModel(_ model: String) -> String {
        model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }

    /// Anthropic has no per-key cost endpoint. Estimate: fetch weighted tokens
    /// per (day, model, key) from the usage report, then split each day's real
    /// cost_report dollars for a model across that day's keys by weight share.
    /// Keeping the day dimension lets one pass yield totalUSD (30d window),
    /// mtdUSD (days on/after the 1st of the current UTC month) and todayUSD.
    /// Cost with no same-day usage attribution for its model is split by that
    /// day's overall weights — or the whole window's weights when the day has
    /// no usage rows at all — so the per-key estimates sum to the
    /// vendor-reported total. Sole exception: cost on a day when the entire
    /// window has zero usage weight is dropped (matches the returns-empty
    /// contract when there is no usage at all).
    public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal] {
        let days = 30
        let startDay = Day.utcToday(now: now.addingTimeInterval(-Double(days) * 86400))
        let endDay = Day.utcToday(now: now.addingTimeInterval(86400))

        // 1) weighted tokens per (day, normalized model, api_key_id)
        var weights: [String: [String: [String: Double]]] = [:]   // day → model → key → weight
        var page: String? = nil
        var hops = 0
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v1/organizations/usage_report/messages"),
                                      resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "starting_at", value: "\(startDay)T00:00:00Z"),
                URLQueryItem(name: "ending_at", value: "\(endDay)T00:00:00Z"),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by[]", value: "api_key_id"),
                URLQueryItem(name: "group_by[]", value: "model"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            comps.queryItems = items
            let resp = try await getJSON(comps.url!, as: UsageResp.self)
            for bucket in resp.data {
                let day = String(bucket.starting_at.prefix(10))
                for row in bucket.results ?? [] {
                    let w = weight(row)
                    guard w > 0 else { continue }
                    let model = Self.normalizeModel(row.model ?? "other")
                    // Workbench traffic has no api_key_id.
                    weights[day, default: [:]][model, default: [:]][row.api_key_id ?? "workbench", default: 0] += w
                }
            }
            page = (resp.has_more == true) ? resp.next_page : nil
            hops += 1
        } while page != nil && hops < 10

        // 2) real dollars per (day, normalized model)
        var costByDayModel: [String: [String: Double]] = [:]
        for r in try await fetchUsage(sinceDaysAgo: days, now: now) {
            costByDayModel[r.day, default: [:]][Self.normalizeModel(r.model), default: 0] += r.costUSD
        }

        // window-wide per-key weights: fallback pool for days with cost but no usage rows
        var windowKeyWeights: [String: Double] = [:]
        for dayWeights in weights.values {
            for keyWeights in dayWeights.values {
                for (key, w) in keyWeights { windowKeyWeights[key, default: 0] += w }
            }
        }

        // 3) allocate day by day; != 0 so negative refunds are spread too
        var perKeyDay: [String: [String: Double]] = [:]           // key → day → usd
        for (day, models) in costByDayModel {
            var unattributed = 0.0
            for (model, cost) in models {
                if let keyWeights = weights[day]?[model], !keyWeights.isEmpty {
                    let total = keyWeights.values.reduce(0, +)
                    for (key, w) in keyWeights { perKeyDay[key, default: [:]][day, default: 0] += cost * w / total }
                } else {
                    unattributed += cost
                }
            }
            if unattributed != 0 {
                var dayKeyWeights: [String: Double] = [:]
                for keyWeights in (weights[day] ?? [:]).values {
                    for (key, w) in keyWeights { dayKeyWeights[key, default: 0] += w }
                }
                let pool = dayKeyWeights.isEmpty ? windowKeyWeights : dayKeyWeights
                let total = pool.values.reduce(0, +)
                if total > 0 {
                    for (key, w) in pool { perKeyDay[key, default: [:]][day, default: 0] += unattributed * w / total }
                }
            }
        }
        guard !perKeyDay.isEmpty else { return [] }

        // 4) window sums + id → name mapping (merge same-named keys)
        let today = Day.utcToday(now: now)
        let monthStart = Day.utcMonthPrefix(now: now) + "-01"
        let names = (try? await fetchKeyNames()) ?? [:]
        var byName: [String: (total: Double, mtd: Double, today: Double)] = [:]
        for (id, dayMap) in perKeyDay {
            let name = names[id] ?? id
            var agg = byName[name] ?? (0, 0, 0)
            for (day, usd) in dayMap {
                agg.total += usd
                if day >= monthStart { agg.mtd += usd }
                if day == today { agg.today += usd }
            }
            byName[name] = agg
        }
        return byName.map { KeyTotal(apiKeyID: $0.key, totalUSD: $0.value.total,
                                     todayUSD: $0.value.today, mtdUSD: $0.value.mtd) }
            .sorted {
                if ($0.mtdUSD ?? 0) != ($1.mtdUSD ?? 0) { return ($0.mtdUSD ?? 0) > ($1.mtdUSD ?? 0) }
                if $0.totalUSD != $1.totalUSD { return $0.totalUSD > $1.totalUSD }
                return $0.apiKeyID < $1.apiKeyID
            }
    }

    private func fetchKeyNames() async throws -> [String: String] {
        var names: [String: String] = [:]
        var afterID: String? = nil
        var hops = 0
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v1/organizations/api_keys"),
                                      resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let afterID { items.append(URLQueryItem(name: "after_id", value: afterID)) }
            comps.queryItems = items
            let resp = try await getJSON(comps.url!, as: KeysListResp.self)
            for key in resp.data where key.name != nil { names[key.id] = key.name }
            afterID = (resp.has_more == true) ? resp.last_id : nil
            hops += 1
        } while afterID != nil && hops < 5
        return names
    }

    public func fetchUsage(sinceDaysAgo: Int, now: Date = Date()) async throws -> [UsageRecord] {
        let startDay = Day.utcToday(now: now.addingTimeInterval(-Double(sinceDaysAgo) * 86400))
        let endDay = Day.utcToday(now: now.addingTimeInterval(86400))   // exclusive upper bound: tomorrow
        var records: [UsageRecord] = []
        var page: String? = nil
        var hops = 0
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v1/organizations/cost_report"),
                                      resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "starting_at", value: "\(startDay)T00:00:00Z"),
                URLQueryItem(name: "ending_at", value: "\(endDay)T00:00:00Z"),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by[]", value: "description"),
                URLQueryItem(name: "limit", value: "31"),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            comps.queryItems = items
            let resp = try await getJSON(comps.url!, as: CostResp.self)
            for bucket in resp.data {
                let day = String(bucket.starting_at.prefix(10))
                for row in bucket.results ?? [] {
                    // Zero rows are kept so vendor-side corrections that zero a
                    // previously nonzero (model, day) overwrite the stale row.
                    let usd = row.amount?.usd ?? 0
                    records.append(UsageRecord(
                        vendor: vendorID, accountID: accountID, apiKeyID: "org",
                        model: row.model ?? row.description ?? "other",
                        day: day, requests: 0, tokensIn: 0, tokensOut: 0, costUSD: usd))
                }
            }
            page = (resp.has_more == true) ? resp.next_page : nil
            hops += 1
        } while page != nil && hops < 5
        // Same (vendor, account, key, model, day) can appear across pages/buckets — merge.
        var merged: [String: UsageRecord] = [:]
        for r in records {
            let key = "\(r.model)|\(r.day)"
            if var existing = merged[key] { existing.costUSD += r.costUSD; merged[key] = existing }
            else { merged[key] = r }
        }
        return Array(merged.values)
    }
}
