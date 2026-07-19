import Foundation

/// Anthropic vendor provider, backed by the Admin Usage & Cost API.
/// Requires an ADMIN API key (sk-ant-admin01-…) — regular API keys can't read
/// org-level reports. Cost data comes from /v1/organizations/cost_report
/// (daily buckets, USD amounts as decimal strings in cents, grouped by
/// description which carries the model). Anthropic has no prepaid balance
/// endpoint and no per-key daily cost breakdown, so fetchBalance is nil and
/// key totals use the protocol default ([]).
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
                    let usd = row.amount?.usd ?? 0
                    guard usd != 0 else { continue }
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
