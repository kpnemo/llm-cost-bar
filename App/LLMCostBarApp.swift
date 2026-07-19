import SwiftUI
import ServiceManagement
import LLMCostBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pairing: PairingController?
    let paths = AppPaths.resolve()

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.removeItem(at: paths.cleanQuitMark)   // we're alive
        // Register the embedded daemon LaunchAgent (idempotent).
        let agent = SMAppService.agent(plistName: "com.mikeb.llmcostd.plist")
        if agent.status != .enabled { try? agent.register() }
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

/// Placeholder — replaced in Task 13 with the real Settings UI (accounts,
/// pairing, menu bar display picker, refresh interval, keep-alive toggle).
struct SettingsView: View {
    var body: some View {
        Text("Settings coming in Task 13")
            .padding(40)
            .frame(width: 360, height: 200)
    }
}

@main
struct LLMCostBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = StoreModel()
    @StateObject private var pairing = PairingController()

    var body: some Scene {
        MenuBarExtra {
            DropdownView()
                .environmentObject(model)
                .environmentObject(pairing)
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
        }
    }

    init() {}
}
