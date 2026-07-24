import Foundation
import SwiftUI
import UserNotifications
import LLMCostBarCore

@MainActor
final class StoreModel: ObservableObject {
    @Published var summary = Summary(todayUSD: 0, monthUSD: 0, last30USD: 0)
    @Published var vendors: [VendorSummary] = []
    @Published var accounts: [AccountRow] = []
    @Published var syncLog: [SyncLogRow] = []
    @Published var config = AppConfig()
    @Published var lastHeartbeat: Date?
    @Published var series: [String: [DayCost]] = [:]
    @Published var subscriptionSources: [SubscriptionSourceRow] = []
    @Published var subscriptionWindows: [SubscriptionWindowRow] = []
    @Published var subscriptionCredits: [SubscriptionCreditRow] = []
    @Published var subscriptionSeries: [String: [SubscriptionPoint]] = [:]
    private var notificationAuthRequested = false

    let paths = AppPaths.resolve()
    let store: UsageStore
    /// App start time: right after launch (esp. post-self-update) the daemon
    /// was just re-bootstrapped and its heartbeat is legitimately missing for
    /// a few seconds — that's "starting", not "paused".
    let launchedAt = Date()
    private var timer: Timer?

    init() {
        // Same open path as daemon; WAL allows concurrent access.
        //
        // Deviation from spec: the spec's `try!` risks a crash-at-launch race —
        // the daemon self-heals a corrupt DB by moving it aside (+ WAL sidecars)
        // and reopening (see Daemon/main.swift openDatabaseWithRecovery), and if
        // the app opens mid-shuffle it could hit a transient failure. Retry once
        // after a brief delay before giving up; still fatalError (not silent
        // fallback) so a genuine failure stays visible instead of being swallowed.
        //
        // Note: this closes over `paths` (a plain struct capture, not `self`) so
        // it's safe to call before all stored properties are initialized.
        func openStore(paths: AppPaths) -> UsageStore? {
            (try? Database.open(at: paths.database)).map(UsageStore.init(db:))
        }
        if let s = openStore(paths: paths) {
            store = s
        } else {
            Thread.sleep(forTimeInterval: 0.5)
            guard let s = openStore(paths: paths) else {
                fatalError("LLMCostBar: could not open database at \(paths.database.path) after retry")
            }
            store = s
        }

        // Consolidate pre-1.3.4 per-vendor keychain items into the single vault
        // item. App-only on purpose: the app created those items, so it reads
        // them without consent prompts; the daemon would prompt per item.
        // No-op on fresh installs and after the first successful run.
        let accountIDs = (try? store.accounts())?.map(\.id) ?? []
        _ = try? KeychainStore().migrateLegacyKeys(accountIDs: accountIDs)

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let today = Day.utcToday(), month = Day.utcMonthPrefix()
        let last30Start = Day.last30Start()
        summary = (try? store.summary(today: today, monthPrefix: month, last30Start: last30Start)) ?? summary
        vendors = (try? store.vendorSummaries(today: today, monthPrefix: month, last30Start: last30Start)) ?? vendors
        accounts = (try? store.accounts()) ?? accounts
        syncLog = (try? store.recentSyncLog(limit: 50)) ?? syncLog
        config = AppConfig.load(from: paths.config)
        let since = Day.utcToday(now: Date().addingTimeInterval(-30 * 86400))
        series = Dictionary(uniqueKeysWithValues: vendors.map {
            ($0.vendor, (try? store.dailyCosts(vendor: $0.vendor, sinceDay: since)) ?? [])
        })
        lastHeartbeat = (try? FileManager.default.attributesOfItem(atPath: paths.heartbeat.path)[.modificationDate]) as? Date

        subscriptionSources = (try? store.subscriptionSources()) ?? subscriptionSources
        subscriptionWindows = (try? store.latestSubscriptionWindows()) ?? subscriptionWindows
        subscriptionCredits = (try? store.subscriptionCredits()) ?? subscriptionCredits
        subscriptionSeries = Dictionary(uniqueKeysWithValues: subscriptionSources.map { src in
            // Sparkline tracks the weekly window: claude seven_day, codex primary.
            let weekly = src.source == SubscriptionSource.claude ? "seven_day" : "primary"
            return (src.source, (try? store.subscriptionSeries(source: src.source, windowID: weekly)) ?? [])
        })
        deliverPendingAlerts()
    }

    /// Daemon detects threshold crossings and writes alert_events; only the app
    /// can post user notifications (llmcostd is a bare tool, no bundle for the
    /// permission dialog). The 30 s refresh doubles as the delivery pump.
    private func deliverPendingAlerts() {
        guard let pending = try? store.undeliveredAlertEvents(), !pending.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        if !notificationAuthRequested {
            notificationAuthRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        for alert in pending {
            let content = UNMutableNotificationContent()
            content.title = "LLM Cost Bar"
            content.body = alert.message
            center.add(UNNotificationRequest(identifier: "alert-\(alert.id)", content: content, trigger: nil))
            try? store.markAlertDelivered(id: alert.id)
        }
    }

    var daemonHealthy: Bool {
        guard let hb = lastHeartbeat else { return false }
        return Date().timeIntervalSince(hb) < 60
    }

    /// Three-state daemon status for UI. The update flow deliberately stops
    /// the daemon before swapping the bundle, so right after (re)launch a
    /// missing heartbeat means "coming up", not "broken" — showing an orange
    /// "not responding" in that window scared users (reported on 1.3.12).
    enum DaemonState { case starting, running, notResponding }
    var daemonState: DaemonState {
        if daemonHealthy { return .running }
        return Date().timeIntervalSince(launchedAt) < 120 ? .starting : .notResponding
    }

    var menuBarTitle: String {
        switch config.menuBarDisplay {
        case .iconOnly: ""
        case .today: String(format: "$%.2f", summary.todayUSD)
        case .monthToDate: String(format: "$%.2f", summary.monthUSD)
        case .last30Days: String(format: "$%.2f", summary.last30USD)
        }
    }

    func saveConfig() {
        try? config.save(to: paths.config)
        refresh()
    }

    func requestSync() {
        try? Data().write(to: paths.syncRequest)
    }
}
