import SwiftUI
import AppKit
import ServiceManagement
import LLMCostBarCore

struct SettingsView: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var pairing: PairingController

    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.badge.key") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            DiagnosticsTab().tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 480, height: 360)
        .onAppear {
            (NSApp.delegate as? AppDelegate)?.pairing = pairing
            pairing.store = model.store
            pairing.onPaired = { model.refresh() }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct AccountsTab: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var pairing: PairingController
    @EnvironmentObject var claudeConnect: ClaudeConnectController
    @State private var showAddFlow = false
    @State private var selectedProvider = "OpenRouter"
    @State private var newName = "personal"

    private struct ProviderInfo {
        let vendor: String
        let keyName: String
        let keyURL: String
        let step1: String
    }
    private let providers: [String: ProviderInfo] = [
        "OpenRouter": ProviderInfo(
            vendor: "openrouter",
            keyName: "management key",
            keyURL: "https://openrouter.ai/settings/provisioning-keys",
            step1: "Open your OpenRouter provisioning keys page and create a *management key* (a regular API key can't read usage):"),
        "Anthropic": ProviderInfo(
            vendor: "anthropic",
            keyName: "Admin API key",
            keyURL: "https://platform.claude.com/settings/admin-keys",
            step1: "Open the Claude Console admin keys page and create an *Admin API key* (sk-ant-admin…). Needs the org *admin* role; individual accounts must first create an organization in Console → Settings → Organization. Usage appears with ~5 min delay:"),
        "OpenAI": ProviderInfo(
            vendor: "openai",
            keyName: "Admin API key",
            keyURL: "https://platform.openai.com/settings/organization/admin-keys",
            step1: "Open the OpenAI admin keys page and create an *Admin API key* (sk-admin…, requires the org *owner* role — project keys can't read org costs):"),
    ]
    private let comingSoon = ["Gemini"]

    var body: some View {
        Form {
            Section("Connected providers") {
                if model.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No providers connected yet.").foregroundStyle(.secondary)
                        Button("Add Provider…") { showAddFlow = true; pairing.state = .idle }
                            .buttonStyle(.borderedProminent)
                    }
                }
                ForEach(model.accounts, id: \.id) { acc in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(acc.vendor.capitalized) — \(acc.displayName)")
                            Text(acc.needsReauth ? "⚠ key rejected — remove and add again with a new management key"
                                 : (acc.lastSyncOK.map { "✓ connected · synced \($0)" } ?? "waiting for first sync…"))
                                .font(.caption).foregroundStyle(acc.needsReauth ? .red : .secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            try? model.store.removeAccount(id: acc.id)
                            try? KeychainStore().deleteKey(accountID: acc.id)
                            model.refresh()
                        }
                    }
                }
                if !model.accounts.isEmpty && !showAddFlow {
                    Button("Add Provider…") { showAddFlow = true; pairing.state = .idle }
                }

                Text("""
                🔒 **About Keychain prompts.** Your API keys are stored only in the \
                macOS Keychain — never in files or logs — in a single shared item. \
                The first time the background sync service reads it, macOS asks for \
                permission (“llmcostd wants to access…”): click **Always Allow** \
                once and it never asks again, no matter how many providers you add. \
                The app never asks from the background: a Keychain dialog can only \
                appear right after you click Connect or Reconnect.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Subscriptions (auto-detected)") {
                if model.subscriptionSources.isEmpty {
                    Text("None detected yet — sign in to Claude Code or Codex CLI on this Mac and they appear here within a few minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.subscriptionSources, id: \.source) { src in
                    Toggle(isOn: Binding(
                        get: { src.enabled },
                        set: { on in
                            try? model.store.setSubscriptionSourceEnabled(source: src.source, enabled: on)
                            model.refresh()
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(src.source == SubscriptionSource.claude ? "Claude (Claude Code)" : "Codex (ChatGPT)")
                            Text(subscriptionStatus(src))
                                .font(.caption)
                                .foregroundStyle(src.stale ? .orange : .secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if src.source == SubscriptionSource.claude && src.enabled {
                        claudeConnectRows(src)
                    }
                }
                if model.subscriptionSources.contains(where: { $0.source == SubscriptionSource.claude }) {
                    Text("Claude limits reuse Claude Code's sign-in from your Keychain, read-only. Connecting asks for Keychain access once; after that the app never prompts on its own — if access is lost (Claude Code rotates its sign-in), a Reconnect button appears instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if showAddFlow {
                Section("Add provider") {
                    Picker("Provider", selection: $selectedProvider) {
                        Text("OpenRouter").tag("OpenRouter")
                        Text("Anthropic").tag("Anthropic")
                        Text("OpenAI").tag("OpenAI")
                        ForEach(comingSoon, id: \.self) { Text("\($0) — coming soon").tag($0).selectionDisabled() }
                    }
                    TextField("Account name", text: $newName)

                    let info = providers[selectedProvider] ?? providers["OpenRouter"]!
                    VStack(alignment: .leading, spacing: 8) {
                        Text("**Step 1.** \(info.step1)")
                            .font(.callout)
                        Button("Open \(selectedProvider) key settings ↗") {
                            NSWorkspace.shared.open(URL(string: info.keyURL)!)
                        }
                        Text("**Step 2.** Copy the new \(info.keyName), come back here, and click:")
                            .font(.callout)
                        Button("Paste key from clipboard & Test connection") {
                            pairing.addProviderFromClipboard(vendor: info.vendor, displayName: newName)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pairing.state == .exchanging)
                    }
                    .padding(.vertical, 4)

                    pairingStatus

                    Button("Cancel") { showAddFlow = false; pairing.cancelPairing() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: pairing.state) {
            if pairing.state == .done { showAddFlow = false }
        }
        .onAppear {
            claudeConnect.store = model.store
            claudeConnect.onChanged = { model.refresh() }
        }
    }

    /// Claude-specific rows under the toggle: the click-gated Reconnect and its
    /// outcome. Failure text renders only while a reconnect is still needed —
    /// once the daemon reports healthy again, stale feedback must not linger.
    /// (The `claude setup-token` path was removed: Anthropic's usage endpoint
    /// rejects setup-tokens — 403, missing user:profile scope.)
    @ViewBuilder private func claudeConnectRows(_ src: SubscriptionSourceRow) -> some View {
        let needsReconnect = src.stale && src.staleReason == ClaudeTokenResolver.reconnectReason
        if needsReconnect {
            HStack {
                Button(claudeButtonTitle) { claudeConnect.connect() }
                    .disabled(claudeConnect.phase == .connecting)
                if claudeConnect.phase == .connecting { ProgressView().controlSize(.small) }
            }
            if case .failed(let msg) = claudeConnect.phase {
                Label(msg, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
            }
        }
        if claudeConnect.phase == .connected {
            Label("Connected ✓ — limits refresh within seconds", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private var claudeButtonTitle: String {
        model.subscriptionWindows.contains { $0.source == SubscriptionSource.claude }
            ? "Reconnect Claude…" : "Connect Claude — macOS will ask once…"
    }

    private func subscriptionStatus(_ src: SubscriptionSourceRow) -> String {
        if src.stale { return "⚠ \(src.staleReason ?? "sign-in required")" }
        if let ok = src.lastOK { return "✓ tracking limits · updated \(ok)" }
        return "detected — waiting for first poll…"
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.state {
        case .idle: EmptyView()
        case .waitingForBrowser:
            HStack {
                Label("Approve access in your browser…", systemImage: "safari")
                Button("Cancel") { pairing.cancelPairing() }
            }
        case .exchanging:
            Label("Testing connection…", systemImage: "arrow.triangle.2.circlepath")
        case .done:
            Label("Connected ✓ — first sync runs within seconds", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle").foregroundStyle(.red)
        }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var updater: UpdaterModel
    @State private var repairState: RepairState = .idle

    enum RepairState: Equatable { case idle, repairing, done, failed }

    var body: some View {
        Form {
            Picker("Menu bar shows", selection: $model.config.menuBarDisplay) {
                Text("Icon only").tag(MenuBarDisplay.iconOnly)
                Text("Today's spend").tag(MenuBarDisplay.today)
                Text("Month to date (MTD)").tag(MenuBarDisplay.monthToDate)
                Text("Last 30 days").tag(MenuBarDisplay.last30Days)
            }
            Picker("Refresh every", selection: $model.config.refreshMinutes) {
                ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
            }
            Picker("Popover opens to", selection: $model.config.defaultTab) {
                Text("API Spend").tag(PopoverTab.apiSpend)
                Text("Subscriptions").tag(PopoverTab.subscriptions)
            }
            Picker("Subscription alert at", selection: $model.config.subscriptionAlertThreshold) {
                ForEach([70, 80, 90, 95], id: \.self) { Text("\($0)% used").tag($0) }
            }
            Toggle("Keep app running (daemon relaunches it if it crashes)", isOn: $model.config.keepAppAlive)
            Toggle("Launch at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in
                    if on { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                }
            ))
            Button("Sync now") { model.requestSync() }

            Section("Updates") {
                LabeledContent("Version", value: updater.currentVersion)
                Toggle("Check for updates automatically (daily)", isOn: $model.config.autoCheckUpdates)
                // The exact same state row as the popover: available → Install,
                // download progress, installing, ✓ updated, failed + Retry.
                UpdateRow()
                if showsCheckButton {
                    HStack {
                        Button("Check for Updates…") { Task { await updater.check() } }
                            .disabled(updater.phase == .checking)
                        if updater.phase == .checking {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if let status = updateStatusLine {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Background service") {
                LabeledContent("Daemon") {
                    Label(model.daemonHealthy ? "running" : "not responding",
                          systemImage: model.daemonHealthy ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(model.daemonHealthy ? .green : .orange)
                }
                if !model.daemonHealthy {
                    Text("If repairing doesn't help, make sure “LLM Cost Bar” is allowed in System Settings → General → Login Items & Extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        repair()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Repair background service")
                            if repairState == .repairing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(repairState == .repairing)
                    Button("Open Login Items Settings…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                switch repairState {
                case .repairing:
                    Text("Restarting the service…").font(.caption).foregroundStyle(.secondary)
                case .done:
                    Label("Service is running again", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                case .failed:
                    Text("Still not responding after repair — check Login Items (button above), then try again.")
                        .font(.caption).foregroundStyle(.orange)
                case .idle:
                    EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.config) { model.saveConfig() }
    }

    /// The 3× launchctl cycle blocks for seconds — it froze the Settings window
    /// when run on the main thread (reported live on 1.3.11). Run it detached
    /// and detect completion by the daemon's own heartbeat instead of a blind
    /// timer: fresh heartbeat = actually running, 12 s without one = failed.
    private func repair() {
        repairState = .repairing
        let heartbeat = model.paths.heartbeat
        Task.detached {
            DaemonManager.ensure(heartbeatURL: heartbeat, force: true)
            var healthy = false
            for _ in 0..<24 {   // up to ~12 s
                try? await Task.sleep(for: .milliseconds(500))
                let age = ((try? FileManager.default
                    .attributesOfItem(atPath: heartbeat.path)[.modificationDate]) as? Date)
                    .map { Date().timeIntervalSince($0) }
                if let age, age < 10 { healthy = true; break }
            }
            await MainActor.run {
                repairState = healthy ? .done : .failed
                model.refresh()
            }
        }
    }

    /// The manual check button hides while an update is known (the UpdateRow's
    /// Install takes over) or an install is in flight.
    private var showsCheckButton: Bool {
        guard updater.availableRelease == nil else { return false }
        switch updater.phase {
        case .downloading, .installing: return false
        default: return true
        }
    }

    private var updateStatusLine: String? {
        if case .failed(let msg) = updater.phase { return "Update failed: \(msg)" }
        guard let last = updater.lastCheck, let result = updater.lastCheckResult else { return nil }
        let time = last.formatted(date: .abbreviated, time: .shortened)
        return "\(result) — last checked \(time)"
    }
}

struct DiagnosticsTab: View {
    @EnvironmentObject var model: StoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Table(model.syncLog) {
                TableColumn("Time") { row in Text(String(row.ts.suffix(9).prefix(8))) }.width(70)
                TableColumn("Vendor", value: \.vendor).width(80)
                TableColumn("Class", value: \.errorClass).width(70)
                TableColumn("Message", value: \.message)
            }
            HStack {
                Button("Copy diagnostics") {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let header = "LLM Cost Bar v\(version) — \(ISO8601DateFormatter().string(from: Date()))"
                    let text = ([header] + model.syncLog.map {
                        "\($0.ts) [\($0.errorClass)] \($0.vendor)/\($0.accountID) \($0.endpoint) " +
                        "status=\($0.httpStatus.map(String.init) ?? "-") \($0.message) \($0.snippet ?? "")"
                    }).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Text(model.daemonHealthy ? "daemon: healthy" : "daemon: not responding")
                    .foregroundStyle(model.daemonHealthy ? .green : .orange)
            }
        }
        .padding()
    }
}
