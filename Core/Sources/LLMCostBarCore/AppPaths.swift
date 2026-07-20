import Foundation

/// Shared filesystem layout for app + daemon. LLMCOSTBAR_HOME env var overrides
/// the base directory (used by tests; also handy for a second dev instance).
public struct AppPaths: Sendable {
    public let base: URL
    public var database: URL      { base.appendingPathComponent("db.sqlite") }
    public var config: URL        { base.appendingPathComponent("config.json") }
    public var heartbeat: URL     { base.appendingPathComponent("daemon-heartbeat") }
    public var syncRequest: URL   { base.appendingPathComponent("sync-request") }
    public var cleanQuitMark: URL { base.appendingPathComponent("app-clean-quit") }
    /// Written by the updater just before relaunch (contains the new version);
    /// the next launch reads+deletes it to show a one-shot "updated" confirmation.
    public var updateInstalledMark: URL { base.appendingPathComponent("update-installed") }

    public static func resolve() -> AppPaths {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["LLMCOSTBAR_HOME"] {
            base = URL(fileURLWithPath: override)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LLMCostBar")
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return AppPaths(base: base)
    }
}
