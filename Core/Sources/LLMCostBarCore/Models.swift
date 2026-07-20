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

/// One API key's spend. All vendors now report a trailing-30-day totalUSD:
/// OpenAI and OpenRouter real dollars (OpenRouter via per-key /activity
/// calls), Anthropic 30-day estimates. todayUSD/mtdUSD are nil only for
/// old daemon data that predates per-key windows.
public struct KeyTotal: Equatable, Sendable {
    public var apiKeyID: String
    public var totalUSD: Double
    public var todayUSD: Double?
    public var mtdUSD: Double?
    public init(apiKeyID: String, totalUSD: Double, todayUSD: Double? = nil, mtdUSD: Double? = nil) {
        self.apiKeyID = apiKeyID; self.totalUSD = totalUSD
        self.todayUSD = todayUSD; self.mtdUSD = mtdUSD
    }
}

extension KeyTotal {
    /// Collapse per-key per-day dollars into window sums (total / MTD / today),
    /// merging distinct key ids that share a display name into one row, sorted
    /// MTD desc, then total desc, then name asc (deterministic across refreshes).
    /// Only totalUSD is clipped to the trailing-30-day window as the vendor
    /// header (Day.last30Start) — providers fetch ~31 days of buckets (today
    /// through today−30) so a key's 30d cell can't systematically exceed the
    /// header total above it, which only ever sums the header's 30-day window.
    /// mtdUSD/todayUSD are NOT clipped to windowStart: on the 31st of a 31-day
    /// month, windowStart falls after the 1st, so clipping there would drop
    /// day-1 spend from MTD while the header's MTD still includes it — mtd is
    /// naturally bounded anyway (at most 31 days, exactly what's fetched).
    static func aggregate(perKeyDay: [String: [String: Double]],
                          names: [String: String], now: Date) -> [KeyTotal] {
        let today = Day.utcToday(now: now)
        let monthStart = Day.utcMonthPrefix(now: now) + "-01"
        let windowStart = Day.last30Start(now: now)
        var byName: [String: (total: Double, mtd: Double, today: Double)] = [:]
        for (id, dayMap) in perKeyDay {
            let name = names[id] ?? id
            var agg = byName[name] ?? (0, 0, 0)
            for (day, usd) in dayMap {
                if day >= windowStart { agg.total += usd }
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
}

public struct Balance: Equatable, Sendable {
    public var balanceUSD: Double
    public var totalCreditsUSD: Double?   // lifetime credits purchased (nil if vendor doesn't expose it)
    public var totalUsageUSD: Double?     // lifetime credits consumed
    public init(balanceUSD: Double, totalCreditsUSD: Double? = nil, totalUsageUSD: Double? = nil) {
        self.balanceUSD = balanceUSD; self.totalCreditsUSD = totalCreditsUSD; self.totalUsageUSD = totalUsageUSD
    }
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
    /// Start of the trailing-30-day window: inclusive; window + today = 30 days.
    public static func last30Start(now: Date = Date()) -> String {
        utcToday(now: now.addingTimeInterval(-29 * 86400))
    }
}
