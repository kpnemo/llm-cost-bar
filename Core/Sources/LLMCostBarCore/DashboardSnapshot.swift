import Foundation

/// A complete refresh result, prepared away from the main actor. Totals derive
/// from the exact vendor rows displayed, so a concurrent daemon update cannot
/// make the header disagree with the cards.
public struct DashboardSnapshot: Sendable {
    public let summary: Summary
    public let vendors: [VendorSummary]
    public let accounts: [AccountRow]
    public let syncLog: [SyncLogRow]
    public let series: [String: [DayCost]]
    public let charts: [String: SpendChart]
    public let subscriptionSources: [SubscriptionSourceRow]
    public let subscriptionWindows: [SubscriptionWindowRow]
    public let subscriptionCredits: [SubscriptionCreditRow]
    public let subscriptionSeries: [String: [SubscriptionPoint]]
    public let pendingAlerts: [AlertEventRow]

    public static func load(from store: UsageStore, now: Date = Date()) throws -> Self {
        let today = Day.utcToday(now: now), month = Day.utcMonthPrefix(now: now)
        let start = Day.last30Start(now: now)
        let vendors = try store.vendorSummaries(today: today, monthPrefix: month, last30Start: start)
        let series = try Dictionary(uniqueKeysWithValues: vendors.map {
            ($0.vendor, try store.dailyCosts(vendor: $0.vendor, sinceDay: start))
        })
        let sources = try store.subscriptionSources()
        return Self(
            summary: Summary(todayUSD: vendors.reduce(0) { $0 + $1.todayUSD },
                             monthUSD: vendors.reduce(0) { $0 + $1.monthUSD },
                             last30USD: vendors.reduce(0) { $0 + $1.last30USD }),
            vendors: vendors, accounts: try store.accounts(), syncLog: try store.recentSyncLog(limit: 50),
            series: series,
            charts: Dictionary(uniqueKeysWithValues: vendors.map {
                ($0.vendor, SpendChart(series: series[$0.vendor] ?? [], todayUSD: $0.todayUSD, now: now))
            }),
            subscriptionSources: sources,
            subscriptionWindows: try store.latestSubscriptionWindows(),
            subscriptionCredits: try store.subscriptionCredits(),
            subscriptionSeries: try Dictionary(uniqueKeysWithValues: sources.map {
                ($0.source, try store.subscriptionSeries(source: $0.source,
                    windowID: $0.source == SubscriptionSource.claude ? "seven_day" : "primary", now: now))
            }),
            pendingAlerts: try store.undeliveredAlertEvents())
    }
}

/// Chart preparation happens once per refresh, never inside Chart's per-mark
/// rendering/hover closures. UTC boundaries match the spend calculations.
public struct SpendChart: Equatable, Sendable {
    public let points: [DayCost]
    public let today: String
    public let todayIsLiveEstimate: Bool

    public init(series: [DayCost], todayUSD: Double, now: Date = Date()) {
        today = Day.utcToday(now: now)
        let byDay = Dictionary(uniqueKeysWithValues: series.map { ($0.day, $0.costUSD) })
        todayIsLiveEstimate = todayUSD > (byDay[today] ?? 0) + 0.005
        points = (0..<30).reversed().map { offset in
            let day = Day.utcToday(now: now.addingTimeInterval(-Double(offset) * 86400))
            return DayCost(day: day, costUSD: offset == 0 ? max(byDay[day] ?? 0, todayUSD) : byDay[day] ?? 0)
        }
    }
}
