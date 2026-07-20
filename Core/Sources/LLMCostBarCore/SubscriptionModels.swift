import Foundation

/// Subscription usage is point-in-time window utilization (percent + reset time),
/// not daily-summed dollars — a parallel data model to UsageRecord, never mixed
/// into usage_daily.

public enum SubscriptionSource {
    public static let claude = "claude"
    public static let codex = "codex"
}

public struct SubscriptionWindow: Equatable, Sendable {
    public var windowID: String      // claude: five_hour|seven_day|seven_day_opus|seven_day_sonnet; codex: primary|secondary
    public var usedPercent: Double   // clamped 0–100
    public var resetsAt: Date?
    public var windowMinutes: Int?
    public init(windowID: String, usedPercent: Double, resetsAt: Date? = nil, windowMinutes: Int? = nil) {
        self.windowID = windowID
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt; self.windowMinutes = windowMinutes
    }

    /// Human label shared by alerts (daemon) and cards (app) so both say the same thing.
    public var label: String {
        switch windowID {
        case "five_hour": return "5-hour"
        case "seven_day": return "7-day"
        case "seven_day_opus": return "7-day Opus"
        case "seven_day_sonnet": return "7-day Sonnet"
        case "primary", "secondary":
            guard let m = windowMinutes else { return windowID == "primary" ? "Primary" : "Secondary" }
            if m == 10080 { return "Weekly" }
            if m % 60 == 0 { return "\(m / 60)-hour" }
            return "\(m)-minute"
        default: return windowID
        }
    }
}

public struct SubscriptionSnapshot: Equatable, Sendable {
    public var source: String        // SubscriptionSource.*
    public var planType: String?     // vendor-reported: "max_5x", "pro", "plus", …
    public var observedAt: Date      // api: fetch time; jsonl: event timestamp
    public var origin: String        // "api" | "jsonl"
    public var windows: [SubscriptionWindow]
    public init(source: String, planType: String?, observedAt: Date, origin: String,
                windows: [SubscriptionWindow]) {
        self.source = source; self.planType = planType
        self.observedAt = observedAt; self.origin = origin; self.windows = windows
    }
}

public struct SubscriptionSourceRow: Equatable, Sendable {
    public var source: String
    public var enabled: Bool
    public var planType: String?
    public var lastOK: String?
    public var stale: Bool
    public var staleReason: String?
}

public struct SubscriptionWindowRow: Equatable, Hashable, Sendable {
    public var source: String
    public var windowID: String
    public var observedAt: String    // ISO8601
    public var usedPercent: Double
    public var resetsAt: String?     // ISO8601
    public var windowMinutes: Int?
    public var origin: String
}

public extension SubscriptionWindowRow {
    /// Same label logic as SubscriptionWindow so alerts and cards agree.
    var label: String {
        SubscriptionWindow(windowID: windowID, usedPercent: usedPercent,
                           resetsAt: nil, windowMinutes: windowMinutes).label
    }
}

public struct SubscriptionPoint: Equatable, Hashable, Sendable {
    public var bucketStart: Date
    public var usedPercent: Double
    public init(bucketStart: Date, usedPercent: Double) {
        self.bucketStart = bucketStart; self.usedPercent = usedPercent
    }
}

public struct AlertEventRow: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var ts: String
    public var rule: String
    public var message: String
}
