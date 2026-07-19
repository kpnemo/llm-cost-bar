import Foundation

/// OpenAI vendor provider, backed by the org Costs API.
/// Requires an ADMIN API key (sk-admin-…, created by an org owner at
/// platform.openai.com → Settings → Organization → Admin keys) — project keys
/// can't read org reports. /v1/organization/costs returns daily buckets with
/// unix-second timestamps and dollar amounts; group_by=line_item carries the
/// model ("GPT-4o, input"), group_by=api_key_id gives real per-key dollars
/// (no estimation needed, unlike Anthropic). No balance endpoint, so
/// fetchBalance is nil.
public struct OpenAIProvider: VendorProvider {
    public let vendorID = "openai"
    let accountID: String
    let credential: Credential
    let http: HTTPClient
    let baseURL: URL

    public init(accountID: String, credential: Credential, http: HTTPClient = URLSessionHTTPClient(),
                baseURL: URL = URL(string: "https://api.openai.com")!) {
        self.accountID = accountID; self.credential = credential; self.http = http; self.baseURL = baseURL
    }

    // MARK: response shapes (tolerant)

    /// Live responses have returned numbers where docs show numbers AND
    /// number-strings (seen in the wild on amount.value) — accept both.
    enum FlexDouble: Decodable {
        case value(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .value(d); return }
            if let s = try? c.decode(String.self), let d = Double(s) { self = .value(d); return }
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath,
                debugDescription: "expected number or numeric string"))
        }
        var double: Double { if case .value(let d) = self { d } else { 0 } }
    }

    private struct CostsResp: Decodable {
        struct Bucket: Decodable { let start_time: FlexDouble; let results: [Row]? }
        struct Amount: Decodable { let value: FlexDouble?; let currency: String? }
        struct Row: Decodable {
            let amount: Amount?
            let line_item: String?
            let project_id: String?
            let api_key_id: String?
        }
        let data: [Bucket]
        let has_more: Bool?
        let next_page: String?
    }

    private struct ProjectsResp: Decodable {
        struct Project: Decodable { let id: String; let name: String? }
        let data: [Project]
        let has_more: Bool?
        let last_id: String?
    }

    private struct ProjectKeysResp: Decodable {
        struct Key: Decodable { let id: String; let name: String? }
        let data: [Key]
        let has_more: Bool?
        let last_id: String?
    }

    private func getJSON<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, status): (Data, Int)
        do { (data, status) = try await http.get(url, bearer: credential.apiKey) }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.transient(String(describing: error)) }
        if let err = classifyHTTP(status: status, data: data) { throw err }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            let snippet = (String(data: data, encoding: .utf8) ?? "<binary>").prefix(300)
            throw ProviderError.decode("decoding \(url.path): \(error) — body: \(snippet)")
        }
    }

    private func costs(startingDaysAgo days: Int, now: Date, groupBy: String,
                       accumulate: (String, CostsResp.Row) -> Void) async throws {
        // Align to UTC midnight so 1d buckets can't straddle two UTC days —
        // otherwise a sync at 18:00 would key each bucket's cost to shifting
        // day boundaries and re-syncs would stop hitting the same upsert rows.
        let start = (Int(now.timeIntervalSince1970) / 86400 - days) * 86400
        var page: String? = nil
        var hops = 0
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v1/organization/costs"),
                                      resolvingAgainstBaseURL: false)!
            var items = [
                URLQueryItem(name: "start_time", value: String(start)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "group_by", value: groupBy),
                URLQueryItem(name: "limit", value: String(min(days + 1, 180))),
            ]
            if let page { items.append(URLQueryItem(name: "page", value: page)) }
            comps.queryItems = items
            let resp = try await getJSON(comps.url!, as: CostsResp.self)
            for bucket in resp.data {
                let day = Day.utcToday(now: Date(timeIntervalSince1970: bucket.start_time.double))
                for row in bucket.results ?? [] { accumulate(day, row) }
            }
            page = (resp.has_more == true) ? resp.next_page : nil
            hops += 1
        } while page != nil && hops < 10
    }

    /// "GPT-4o, input" / "GPT-4o, output" → "GPT-4o"; non-token line items
    /// ("Code interpreter sessions") pass through whole.
    static func modelFromLineItem(_ lineItem: String?) -> String {
        guard let lineItem, !lineItem.isEmpty else { return "other" }
        return String(lineItem.split(separator: ",").first ?? "other")
            .trimmingCharacters(in: .whitespaces)
    }

    public func validateCredentials() async throws -> AccountInfo {
        _ = try await fetchUsage(sinceDaysAgo: 2, now: Date())
        return AccountInfo(label: "openai-admin")
    }

    public func fetchBalance() async throws -> Balance? { nil }

    public func fetchUsage(sinceDaysAgo: Int, now: Date = Date()) async throws -> [UsageRecord] {
        var merged: [String: UsageRecord] = [:]
        try await costs(startingDaysAgo: sinceDaysAgo, now: now, groupBy: "line_item") { day, row in
            // Zero rows are kept: a vendor-side correction that zeroes a previously
            // nonzero (model, day) must overwrite the stale row via the upsert.
            let usd = row.amount?.value?.double ?? 0
            let model = Self.modelFromLineItem(row.line_item)
            let key = "\(model)|\(day)"
            if var existing = merged[key] { existing.costUSD += usd; merged[key] = existing }
            else {
                merged[key] = UsageRecord(vendor: vendorID, accountID: accountID, apiKeyID: "org",
                                          model: model, day: day, requests: 0,
                                          tokensIn: 0, tokensOut: 0, costUSD: usd)
            }
        }
        return Array(merged.values)
    }

    /// Real per-day per-key dollars over the last 30 days (group_by=api_key_id).
    /// Rows without a key (dashboard/playground and non-key costs) are skipped
    /// rather than shown as a phantom key.
    public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal] {
        var perKeyDay: [String: [String: Double]] = [:]           // key → day → usd
        try await costs(startingDaysAgo: 30, now: now, groupBy: "api_key_id") { day, row in
            guard let keyID = row.api_key_id, let usd = row.amount?.value?.double, usd != 0 else { return }
            perKeyDay[keyID, default: [:]][day, default: 0] += usd
        }
        guard !perKeyDay.isEmpty else { return [] }
        let names = (try? await fetchKeyNames()) ?? [:]
        return KeyTotal.aggregate(perKeyDay: perKeyDay, names: names, now: now)
    }

    /// key_… ids → names, via projects → per-project API keys (best effort).
    /// Both lists paginate with has_more/last_id (after=… cursor).
    private func fetchKeyNames() async throws -> [String: String] {
        var names: [String: String] = [:]
        var projectAfter: String? = nil
        var projectHops = 0
        repeat {
            var comps = URLComponents(url: baseURL.appendingPathComponent("v1/organization/projects"),
                                      resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let projectAfter { items.append(URLQueryItem(name: "after", value: projectAfter)) }
            comps.queryItems = items
            let projects = try await getJSON(comps.url!, as: ProjectsResp.self)
            for project in projects.data {
                var keyAfter: String? = nil
                var keyHops = 0
                repeat {
                    var keyComps = URLComponents(url: baseURL.appendingPathComponent("v1/organization/projects/\(project.id)/api_keys"),
                                                 resolvingAgainstBaseURL: false)!
                    var keyItems = [URLQueryItem(name: "limit", value: "100")]
                    if let keyAfter { keyItems.append(URLQueryItem(name: "after", value: keyAfter)) }
                    keyComps.queryItems = keyItems
                    guard let keys = try? await getJSON(keyComps.url!, as: ProjectKeysResp.self) else { break }
                    for key in keys.data where key.name != nil { names[key.id] = key.name }
                    keyAfter = (keys.has_more == true) ? keys.last_id : nil
                    keyHops += 1
                } while keyAfter != nil && keyHops < 5
            }
            projectAfter = (projects.has_more == true) ? projects.last_id : nil
            projectHops += 1
        } while projectAfter != nil && projectHops < 5
        return names
    }
}
