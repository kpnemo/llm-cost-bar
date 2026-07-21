import SwiftUI
import ServiceManagement
import LLMCostBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pairing: PairingController?
    let paths = AppPaths.resolve()

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.removeItem(at: paths.cleanQuitMark)   // we're alive
        // Off the main thread: BTM unregister + 3× launchctl block for seconds.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.purgeLegacyBTMRegistration()
            self.ensureDaemonRegistered()
        }
        scheduleDaemonHealthRecheck()
    }

    /// Kill the pre-LaunchAgent SMAppService registration for good. Seen live
    /// 2026-07-22: BTM still held an ENABLED record for llmcostd (generation
    /// 20, "submitted by smd", with a launch constraint) that re-submits at
    /// every login/update and races the classic LaunchAgent for the same
    /// label — the recurring post-update "daemon not responding" window. The
    /// old cleanup inside DaemonManager.ensure ran only when the plist
    /// changed and swallowed errors; this runs EVERY launch until the record
    /// is gone, and logs the outcome.
    private static func purgeLegacyBTMRegistration() {
        let sm = SMAppService.agent(plistName: "com.mikeb.llmcostd.plist")
        let status = sm.status
        // Attempt unconditionally (except when the plist is missing from the
        // bundle): on 1.3.12 the status-gated version silently skipped — the
        // BTM record stayed "enabled" in dumpbtm while SMAppService reported
        // a different status for the current bundle generation. A redundant
        // unregister on an unregistered service is a harmless error we log.
        guard status != .notFound else { return }
        do {
            try sm.unregister()
            NSLog("LLMCostBar: BTM unregister ok (status was %d)", status.rawValue)
        } catch {
            NSLog("LLMCostBar: BTM unregister (status %d): %@", status.rawValue, String(describing: error))
        }
    }

    private func ensureDaemonRegistered() {
        DaemonManager.ensure(heartbeatURL: paths.heartbeat)
    }

    /// Self-heal for the post-update wedge (seen live on 1.3.6→1.3.7): the
    /// installer's kickstart can race the freshly written bundle, the first
    /// spawn dies on code signing, and launchd wedges the service record in
    /// EX_CONFIG spawn failures instead of retrying. A full bootout/bootstrap
    /// cycle clears it — run one automatically if the daemon hasn't written a
    /// heartbeat within 20 s of app launch.
    private func scheduleDaemonHealthRecheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            let age = ((try? FileManager.default
                .attributesOfItem(atPath: self.paths.heartbeat.path)[.modificationDate]) as? Date)
                .map { Date().timeIntervalSince($0) }
            let daemonLooksAlive = age.map { $0 < 60 } ?? false
            if !daemonLooksAlive {
                DispatchQueue.global(qos: .userInitiated).async {
                    DaemonManager.ensure(heartbeatURL: self.paths.heartbeat, force: true)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? Data().write(to: paths.cleanQuitMark)   // normal quit → watchdog stands down
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "llmcostbar" {
            pairing?.handleCallback(url: url)
        }
    }
}

/// Manages the daemon as a classic user LaunchAgent (~/Library/LaunchAgents).
/// Deliberately NOT SMAppService: BTM records a launch constraint (LWCR) for
/// registered agents which, for locally dev-signed builds, pins the exact binary —
/// after any rebuild the kernel SIGKILLs the daemon ("Launch Constraint Violation")
/// and launchd wedges in EX_CONFIG spawn failures. A plain LaunchAgent has no
/// constraint and survives rebuilds; the plist is rewritten whenever the app moves.
enum DaemonManager {
    static let label = "com.mikeb.llmcostd"

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Idempotent: (re)installs the agent only when the plist is out of date or the
    /// daemon looks dead. Safe to call on every app launch.
    static func ensure(heartbeatURL: URL, force: Bool = false) {
        let daemonPath = Bundle.main.bundlePath + "/Contents/MacOS/llmcostd"
        let plist: [String: Any] = [
            "Label": label,
            "Program": daemonPath,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "ThrottleInterval": 60,
            "StandardOutPath": "/tmp/llmcostd.out.log",
            "StandardErrorPath": "/tmp/llmcostd.err.log",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }

        let changed = (try? Data(contentsOf: plistURL)) != data
        let heartbeatAge = (try? FileManager.default
            .attributesOfItem(atPath: heartbeatURL.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) }
        let daemonLooksAlive = heartbeatAge.map { $0 < 120 } ?? false
        // The heartbeat file survives the process: right after an update
        // (installer boots the service out before the bundle swap) it can be
        // seconds old while NOTHING is registered — trusting it left the
        // daemon unarmed until the 20 s safety net (seen live twice on
        // 2026-07-22). launchd itself is the authority on registration.
        let registered = runLaunchctl(["print", "gui/\(getuid())/\(label)"]) == 0
        guard force || changed || !registered || !daemonLooksAlive else { return }

        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: plistURL)

        // One-time cleanup of any previous SMAppService/BTM registration.
        let sm = SMAppService.agent(plistName: "com.mikeb.llmcostd.plist")
        if sm.status == .enabled { try? sm.unregister() }

        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(label)"])          // ignore failure
        runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
        runLaunchctl(["kickstart", "gui/\(uid)/\(label)"])
    }

    /// Stops the daemon and removes it from launchd (updater: must happen before
    /// the bundle swap so the watchdog can't relaunch the old app mid-install).
    static func bootout() {
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice   // `print` dumps pages we don't need
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

@main
struct LLMCostBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = StoreModel()
    @StateObject private var pairing = PairingController()
    @StateObject private var updater = UpdaterModel()
    @StateObject private var claudeConnect = ClaudeConnectController()

    var body: some Scene {
        MenuBarExtra {
            DropdownView()
                .environmentObject(model)
                .environmentObject(pairing)
                .environmentObject(updater)
                .environmentObject(claudeConnect)
        } label: {
            // Placeholder glyph until icon concepts are chosen (spec open item).
            HStack(spacing: 3) {
                Image(systemName: "dollarsign.gauge.chart.lefthalf.righthalf")
                if !model.menuBarTitle.isEmpty { Text(model.menuBarTitle) }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(pairing)
                .environmentObject(updater)
                .environmentObject(claudeConnect)
        }
    }

    init() {}
}
