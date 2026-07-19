import Foundation

public struct UsageRecord: Equatable, Sendable {
    public var vendor: String        // "openrouter"
    public var accountID: String
    public var apiKeyID: String      // key label/hash; "default" when vendor gives no breakdown
    public var model: String
    public var day: String           // "yyyy-MM-dd" (UTC — vendors report UTC days)
    public var requests: Int
    public var tokensIn: Int
    public var tokensOut: Int
    public var costUSD: Double
    public init(vendor: String, accountID: String, apiKeyID: String, model: String, day: String,
                requests: Int, tokensIn: Int, tokensOut: Int, costUSD: Double) {
        self.vendor = vendor; self.accountID = accountID; self.apiKeyID = apiKeyID
        self.model = model; self.day = day; self.requests = requests
        self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.costUSD = costUSD
    }
}

public struct Balance: Equatable, Sendable {
    public var balanceUSD: Double
    public init(balanceUSD: Double) { self.balanceUSD = balanceUSD }
}

public struct AccountInfo: Equatable, Sendable {
    public var label: String
    public init(label: String) { self.label = label }
}

public struct Credential: Sendable {
    public var apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }
}

/// Shared identifiers used by both the App and daemon targets.
public enum AppIDs {
    public static let app = "com.mikeb.LLMCostBar"
    public static let daemonLabel = "com.mikeb.llmcostd"
    public static let subsystem = "com.mikeb.llmcostbar"
}

/// Error taxonomy drives sync behavior: transient → retry/backoff, auth → needs_reauth, decode → log loudly.
public enum ProviderError: Error, Equatable, Sendable {
    case transient(String)               // network, timeout, 429, 5xx
    case auth(Int, String)               // 401/403 — do NOT retry
    case http(Int, String)               // other unexpected status (snippet included)
    case decode(String)                  // response shape changed

    public var errorClass: String {
        switch self {
        case .transient: "transient"; case .auth: "auth"; case .http: "http"; case .decode: "decode"
        }
    }
}

public enum Day {
    /// Today's date as "yyyy-MM-dd" in UTC.
    public static func utcToday(now: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: now)
    }
    /// "yyyy-MM" prefix of the current UTC month.
    public static func utcMonthPrefix(now: Date = Date()) -> String {
        String(utcToday(now: now).prefix(7))
    }
}
