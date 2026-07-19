import Foundation
import AppKit
import LLMCostBarCore
import GRDB
import os

let log = Logger(subsystem: AppIDs.subsystem, category: "daemon")
let paths = AppPaths.resolve()

func openDatabaseWithRecovery() -> DatabasePool? {
    do { return try Database.open(at: paths.database) }
    catch {
        log.fault("db open failed: \(String(describing: error), privacy: .public) — moving DB aside and retrying")
        let backup = paths.database.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: paths.database, to: backup)
        // WAL sidecars must move too or the fresh DB inherits them
        for ext in ["-wal", "-shm"] {
            try? FileManager.default.moveItem(
                at: URL(fileURLWithPath: paths.database.path + ext),
                to: URL(fileURLWithPath: backup.path + ext))
        }
        do { return try Database.open(at: paths.database) }
        catch {
            log.fault("db open failed after recovery attempt: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

guard let pool = openDatabaseWithRecovery() else {
    // exit non-zero; launchd (with ThrottleInterval) restarts us with backoff instead of a hot trap loop
    exit(1)
}

let store = UsageStore(db: pool)
let keychain = KeychainStore()
let engine = SyncEngine(store: store, paths: paths,
                        providerFactory: SyncEngine.defaultProviderFactory,
                        credentialLookup: { id in
                            (try? keychain.getKey(accountID: id)).flatMap { $0 }.map { Credential(apiKey: $0) }
                        })

let appBundleID = AppIDs.app
var lastSync = Date.distantPast
var lastRelaunchAttempt = Date.distantPast

func syncIsDue(config: AppConfig) -> Bool {
    if FileManager.default.fileExists(atPath: paths.syncRequest.path) {
        try? FileManager.default.removeItem(at: paths.syncRequest)   // consume trigger
        return true
    }
    return Date().timeIntervalSince(lastSync) >= Double(config.refreshMinutes) * 60
}

/// Relaunch the app only if it is not running AND it did not exit cleanly
/// (the app writes cleanQuitMark on normal quit and removes it on launch).
func watchdog(config: AppConfig) {
    guard config.keepAppAlive else { return }
    guard NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty else { return }
    guard !FileManager.default.fileExists(atPath: paths.cleanQuitMark.path) else { return }
    guard Date().timeIntervalSince(lastRelaunchAttempt) >= 60 else { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else { return }
    log.info("watchdog: app not running and no clean-quit mark — relaunching")
    lastRelaunchAttempt = Date()
    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, err in
        if let err {
            log.error("watchdog relaunch failed: \(String(describing: err), privacy: .public)")
        }
    }
}

log.info("llmcostd started, home: \(paths.base.path, privacy: .public)")

Task {
    while true {
        let config = AppConfig.load(from: paths.config)
        if syncIsDue(config: config) {
            lastSync = Date()
            await engine.syncAll()
        }
        watchdog(config: config)
        try? Data().write(to: paths.heartbeat)
        try? await Task.sleep(for: .seconds(5))
    }
}
RunLoop.main.run()
