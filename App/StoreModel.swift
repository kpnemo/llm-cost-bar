import Foundation
import SwiftUI
import UserNotifications
import Observation
import LLMCostBarCore

@MainActor
@Observable
final class StoreModel {
    var summary = Summary(todayUSD: 0, monthUSD: 0, last30USD: 0)
    var vendors: [VendorSummary] = []
    var accounts: [AccountRow] = []
    var syncLog: [SyncLogRow] = []
    var config = AppConfig() { didSet { configRevision &+= 1 } }
    var lastHeartbeat: Date?
    /// Only time-dependent status views observe this; charts stay untouched.
    var statusDate = Date()
    var series: [String: [DayCost]] = [:]
    var charts: [String: SpendChart] = [:]
    var subscriptionSources: [SubscriptionSourceRow] = []
    var subscriptionWindows: [SubscriptionWindowRow] = []
    var subscriptionCredits: [SubscriptionCreditRow] = []
    var subscriptionSeries: [String: [SubscriptionPoint]] = [:]
    @ObservationIgnored private var notificationAuthRequested = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var configRevision: UInt = 0
    @ObservationIgnored private var configSaveTask: Task<Void, Never>?
    @ObservationIgnored private var lastSavedConfig: AppConfig?
    @ObservationIgnored private var worker: DashboardWorker!

    let paths: AppPaths
    let store: UsageStore
    /// App start time: right after launch (esp. post-self-update) the daemon
    /// was just re-bootstrapped and its heartbeat is legitimately missing for
    /// a few seconds — that's "starting", not "paused".
    let launchedAt = Date()
    @ObservationIgnored private var timer: Timer?

    init(store suppliedStore: UsageStore? = nil, paths: AppPaths = .resolve(), startPolling: Bool = true) {
        self.paths = paths
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
        if let suppliedStore {
            store = suppliedStore
        } else if let s = openStore(paths: paths) {
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
        if suppliedStore == nil {
            let accountIDs = (try? store.accounts())?.map(\.id) ?? []
            _ = try? KeychainStore().migrateLegacyKeys(accountIDs: accountIDs)
        }

        config = AppConfig.load(from: paths.config)
        lastSavedConfig = config
        worker = DashboardWorker(store: store, paths: paths)
        guard startPolling else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Only the returned values are applied on MainActor. Calls while a load is
    /// in flight coalesce into one follow-up, so a slow disk cannot build a queue.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let refreshTask { refreshAgain = true; return refreshTask }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                refreshAgain = false
                let revision = configRevision
                let canReloadConfig = configSaveTask == nil
                let start = ProcessInfo.processInfo.systemUptime
                do {
                    let result = try await worker.load()
                    let applyStart = ProcessInfo.processInfo.systemUptime
                    apply(result.snapshot)
                    if lastHeartbeat != result.heartbeat { lastHeartbeat = result.heartbeat }
                    // A load started before a settings edit must never undo it.
                    if canReloadConfig, configSaveTask == nil, revision == configRevision,
                       config != result.config {
                        lastSavedConfig = result.config
                        config = result.config
                    }
                    deliverPendingAlerts(result.snapshot.pendingAlerts)
                    PerformanceLog.shared.duration("refresh", since: start, fields: [
                        "worker_ms": PerformanceLog.milliseconds(result.loadDuration),
                        "apply_ms": PerformanceLog.milliseconds(ProcessInfo.processInfo.systemUptime - applyStart)
                    ])
                } catch {
                    // Preserve the complete last-good screen; never flash zeros.
                    PerformanceLog.shared.record("refresh_failed", fields: ["error_type": String(describing: type(of: error))])
                }
                statusDate = Date()
            } while refreshAgain && !Task.isCancelled
            refreshTask = nil
        }
        return refreshTask!
    }

    private func apply(_ next: DashboardSnapshot) {
        if summary != next.summary { summary = next.summary }
        if vendors != next.vendors { vendors = next.vendors }
        if accounts != next.accounts { accounts = next.accounts }
        if syncLog != next.syncLog { syncLog = next.syncLog }
        if series != next.series { series = next.series }
        if charts != next.charts { charts = next.charts }
        if subscriptionSources != next.subscriptionSources { subscriptionSources = next.subscriptionSources }
        if subscriptionWindows != next.subscriptionWindows { subscriptionWindows = next.subscriptionWindows }
        if subscriptionCredits != next.subscriptionCredits { subscriptionCredits = next.subscriptionCredits }
        if subscriptionSeries != next.subscriptionSeries { subscriptionSeries = next.subscriptionSeries }
    }

    /// Daemon detects threshold crossings and writes alert_events; only the app
    /// can post user notifications (llmcostd is a bare tool, no bundle for the
    /// permission dialog). The 30 s refresh doubles as the delivery pump.
    private func deliverPendingAlerts(_ pending: [AlertEventRow]) {
        guard !pending.isEmpty else { return }
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
            Task { try? await worker.markAlertDelivered(id: alert.id) }
        }
    }

    var daemonHealthy: Bool {
        guard let hb = lastHeartbeat else { return false }
        return statusDate.timeIntervalSince(hb) < 60
    }

    /// Three-state daemon status for UI. The update flow deliberately stops
    /// the daemon before swapping the bundle, so right after (re)launch a
    /// missing heartbeat means "coming up", not "broken" — showing an orange
    /// "not responding" in that window scared users (reported on 1.3.12).
    enum DaemonState { case starting, running, notResponding }
    var daemonState: DaemonState {
        if daemonHealthy { return .running }
        return statusDate.timeIntervalSince(launchedAt) < 120 ? .starting : .notResponding
    }

    var menuBarTitle: String {
        switch config.menuBarDisplay {
        case .iconOnly: ""
        case .today: String(format: "$%.2f", summary.todayUSD)
        case .monthToDate: String(format: "$%.2f", summary.monthUSD)
        case .last30Days: String(format: "$%.2f", summary.last30USD)
        }
    }

    @discardableResult
    func saveConfig() -> Task<Void, Never>? {
        guard config != lastSavedConfig else { return nil }
        let value = config
        let saveRevision = configRevision
        lastSavedConfig = value
        let previous = configSaveTask
        configSaveTask = Task {
            await previous?.value
            do { try await worker.saveConfig(value) }
            catch {
                if lastSavedConfig == value { lastSavedConfig = nil }
                PerformanceLog.shared.record("config_save_failed")
            }
            // Only the newest save clears the pending flag.
            if configRevision == saveRevision { configSaveTask = nil }
        }
        return configSaveTask
    }

    func requestSync() {
        Task { try? await worker.requestSync() }
    }
}

/// Actor isolation keeps synchronous GRDB/file reads on the worker executor.
/// SwiftUI observes StoreModel properties individually, not this worker's state.
private actor DashboardWorker {
    let store: UsageStore
    let paths: AppPaths
    init(store: UsageStore, paths: AppPaths) { self.store = store; self.paths = paths }
    struct Result: Sendable {
        let snapshot: DashboardSnapshot
        let config: AppConfig
        let heartbeat: Date?
        let loadDuration: TimeInterval
    }
    func load() throws -> Result {
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try DashboardSnapshot.load(from: store)
        let config = AppConfig.load(from: paths.config)
        let heartbeat = (try? FileManager.default.attributesOfItem(atPath: paths.heartbeat.path)[.modificationDate]) as? Date
        return Result(snapshot: snapshot, config: config, heartbeat: heartbeat,
                      loadDuration: ProcessInfo.processInfo.systemUptime - start)
    }
    func saveConfig(_ config: AppConfig) throws { try config.save(to: paths.config) }
    func requestSync() throws { try Data().write(to: paths.syncRequest) }
    func markAlertDelivered(id: Int64) throws { try store.markAlertDelivered(id: id) }
}
