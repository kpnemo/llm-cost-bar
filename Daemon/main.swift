import Foundation
import AppKit
import LLMCostBarCore
import os

let log = Logger(subsystem: "com.mikeb.llmcostbar", category: "daemon")
let paths = AppPaths.resolve()
let pool = try Database.open(at: paths.database)
let store = UsageStore(db: pool)
let keychain = KeychainStore()
let engine = SyncEngine(store: store, paths: paths,
                        providerFactory: SyncEngine.defaultProviderFactory,
                        credentialLookup: { id in
                            (try? keychain.getKey(accountID: id)).flatMap { $0 }.map { Credential(apiKey: $0) }
                        })

let appBundleID = "com.mikeb.LLMCostBar"
var lastSync = Date.distantPast

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
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) else { return }
    log.info("watchdog: app not running and no clean-quit mark — relaunching")
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
