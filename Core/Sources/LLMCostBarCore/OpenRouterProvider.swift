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
            let usage: Double?
            let disabled: Bool?
        }
        let data: [K]
    }
    private struct KeyResp: Decodable {
        struct D: Decodable { let label: String? }
        let data: D
    }

    private func getJSON<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
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
        return Balance(balanceUSD: resp.data.total_credits - resp.data.total_usage)
    }

    public func fetchKeyTotals() async throws -> [KeyTotal] {
        let resp = try await getJSON("keys", as: KeysListResp.self)
        return resp.data.map {
            KeyTotal(apiKeyID: $0.name ?? $0.label ?? "unnamed", totalUSD: $0.usage ?? 0)
        }
    }

    public func fetchUsage(sinceDaysAgo: Int, now: Date = Date()) async throws -> [UsageRecord] {
        // /activity returns the whole recent window; sinceDaysAgo filters client-side.
        let keyLabel = (try? await validateCredentials().label) ?? "default"
        let resp = try await getJSON("activity", as: ActivityResp.self)
        let cutoff = Day.utcToday(now: now.addingTimeInterval(-Double(sinceDaysAgo) * 86400))
        return resp.data.filter { $0.date >= cutoff }.map { row in
            UsageRecord(vendor: vendorID, accountID: accountID, apiKeyID: keyLabel,
                        // Live API returns "2026-07-18 00:00:00"; normalize to the bare
                        // day key the store's exact-match queries use.
                        model: row.model, day: String(row.date.prefix(10)),
                        requests: row.requests ?? 0,
                        tokensIn: row.prompt_tokens ?? 0, tokensOut: row.completion_tokens ?? 0,
                        costUSD: row.usage)
        }
    }
}
