import Foundation

public protocol VendorProvider: Sendable {
    var vendorID: String { get }
    func validateCredentials() async throws -> AccountInfo
    func fetchUsage(sinceDaysAgo: Int, now: Date) async throws -> [UsageRecord]
    func fetchBalance() async throws -> Balance?      // nil if vendor has no prepaid balance
    func fetchKeyTotals(now: Date) async throws -> [KeyTotal]  // per-key today/MTD/30d windows; [] if unsupported
}

public extension VendorProvider {
    func fetchKeyTotals(now: Date) async throws -> [KeyTotal] { [] }
}

/// Retries transient errors only (network/429/5xx). Auth and decode errors surface immediately.
public func withRetry<T: Sendable>(attempts: Int = 3,
                                   sleeper: @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                                   _ op: @Sendable () async throws -> T) async throws -> T {
    var lastError: Error = ProviderError.transient("no attempts")
    for attempt in 0..<attempts {
        do { return try await op() }
        catch let e as ProviderError {
            guard case .transient = e else { throw e }
            lastError = e
            if attempt < attempts - 1 { await sleeper(pow(2.0, Double(attempt))) } // 1s, 2s
        }
        catch {
            // Unknown error → treat as transient (retry), and back off too — previously
            // this path skipped the sleeper, spinning in a tight retry loop with no delay.
            lastError = ProviderError.transient(String(describing: error))
            if attempt < attempts - 1 { await sleeper(pow(2.0, Double(attempt))) }
        }
    }
    throw lastError
}

/// Maps an HTTP status + body to the error taxonomy. Snippet is truncated and never includes headers.
public func classifyHTTP(status: Int, data: Data) -> ProviderError? {
    let snippet = (String(data: data, encoding: .utf8) ?? "<binary>").prefix(300)
    switch status {
    case 200...299: return nil
    case 401, 403: return .auth(status, String(snippet))
    case 429, 500...599: return .transient("HTTP \(status): \(snippet)")
    default: return .http(status, String(snippet))
    }
}
