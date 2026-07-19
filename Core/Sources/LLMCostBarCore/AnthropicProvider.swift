import Foundation

/// Anthropic vendor provider, backed by the Admin Usage & Cost API.
/// Requires an ADMIN API key (sk-ant-admin01-…) — regular API keys can't read
/// org-level reports. Cost data comes from /v1/organizations/cost_report
/// (daily buckets, USD amounts as decimal strings in cents, grouped by
/// description which carries the model). Anthropic has no prepaid balance
/// endpoint, so fetchBalance is nil. Per-key dollars are not exposed either
/// (cost_report only groups by workspace/description), so fetchKeyTotals
/// estimates them: each model's real cost is split across keys in proportion
/// to price-weighted tokens from the usage report.
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
    /// per (model, key) from the usage report, then split each model's real
    /// cost_report dollars across its keys by weight share. Cost on models
    /// with no usage attribution is split by overall weight share, so the
    /// per-key estimates always sum to the vendor-reported total.
    public func fetchKeyTotals() async throws -> [KeyTotal] {
        let days = 30
        let now = Date()
        let startDay = Day.utcToday(now: now.addingTimeInterval(-Double(days) * 86400))
        let endDay = Day.utcToday(now: now.addingTimeInterval(86400))

        // 1) weighted tokens per (normalized model, api_key_id)
        var weights: [String: [String: Double]] = [:]
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
                for row in bucket.results ?? [] {
                    let w = weight(row)
                    guard w > 0 else { continue }
                    let model = Self.normalizeModel(row.model ?? "other")
                    // Workbench traffic has no api_key_id.
                    weights[model, default: [:]][row.api_key_id ?? "workbench", default: 0] += w
                }
            }
            page = (resp.has_more == true) ? resp.next_page : nil
            hops += 1
        } while page != nil && hops < 10

        // 2) real dollars per model over the same window
        var costByModel: [String: Double] = [:]
        for r in try await fetchUsage(sinceDaysAgo: days, now: now) {
            costByModel[Self.normalizeModel(r.model), default: 0] += r.costUSD
        }

        // 3) allocate each model's cost by weight share
        var estimate: [String: Double] = [:]
        var unattributed = 0.0
        for (model, cost) in costByModel {
            if let keyWeights = weights[model] {
                let total = keyWeights.values.reduce(0, +)
                for (key, w) in keyWeights { estimate[key, default: 0] += cost * w / total }
            } else {
                unattributed += cost
            }
        }
        // != 0, not > 0: negative unattributed cost (refunds/credits under a
        // description with no usage rows) must also be spread, or the per-key
        // sum drifts above the vendor-reported total.
        if unattributed != 0 {
            var perKey: [String: Double] = [:]
            for keyWeights in weights.values {
                for (key, w) in keyWeights { perKey[key, default: 0] += w }
            }
            let total = perKey.values.reduce(0, +)
            if total > 0 {
                for (key, w) in perKey { estimate[key, default: 0] += unattributed * w / total }
            }
        }
        guard !estimate.isEmpty else { return [] }

        // 4) apikey_… ids → display names (best effort; ids shown on failure)
        let names = (try? await fetchKeyNames()) ?? [:]
        var byName: [String: Double] = [:]
        for (id, usd) in estimate { byName[names[id] ?? id, default: 0] += usd }
        return byName.map { KeyTotal(apiKeyID: $0.key, totalUSD: $0.value) }
            .sorted { $0.totalUSD > $1.totalUSD }
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
