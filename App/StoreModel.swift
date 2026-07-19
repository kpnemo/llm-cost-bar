import Foundation
import SwiftUI
import LLMCostBarCore

@MainActor
final class StoreModel: ObservableObject {
    @Published var summary = Summary(todayUSD: 0, monthUSD: 0)
    @Published var vendors: [VendorSummary] = []
    @Published var accounts: [AccountRow] = []
    @Published var syncLog: [SyncLogRow] = []
    @Published var config = AppConfig()
    @Published var lastHeartbeat: Date?

    let paths = AppPaths.resolve()
    let store: UsageStore
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

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let today = Day.utcToday(), month = Day.utcMonthPrefix()
        summary = (try? store.summary(today: today, monthPrefix: month)) ?? summary
        vendors = (try? store.vendorSummaries(today: today, monthPrefix: month)) ?? vendors
        accounts = (try? store.accounts()) ?? accounts
        syncLog = (try? store.recentSyncLog(limit: 50)) ?? syncLog
        config = AppConfig.load(from: paths.config)
        lastHeartbeat = (try? FileManager.default.attributesOfItem(atPath: paths.heartbeat.path)[.modificationDate]) as? Date
    }

    var daemonHealthy: Bool {
        guard let hb = lastHeartbeat else { return false }
        return Date().timeIntervalSince(hb) < 60
    }

    var menuBarTitle: String {
        switch config.menuBarDisplay {
        case .iconOnly: ""
        case .today: String(format: "$%.2f", summary.todayUSD)
        case .monthToDate: String(format: "$%.2f", summary.monthUSD)
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
