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
                }
                if model.subscriptionSources.contains(where: { $0.source == SubscriptionSource.claude }) {
                    Text("Claude limits reuse Claude Code's sign-in from your Keychain (read-only). When macOS asks, click “Always Allow”.")
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
                    Button("Repair background service") {
                        DaemonManager.ensure(heartbeatURL: model.paths.heartbeat, force: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.refresh() }
                    }
                    Button("Open Login Items Settings…") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.config) { model.saveConfig() }
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
                    let text = model.syncLog.map {
                        "\($0.ts) [\($0.errorClass)] \($0.vendor)/\($0.accountID) \($0.endpoint) " +
                        "status=\($0.httpStatus.map(String.init) ?? "-") \($0.message) \($0.snippet ?? "")"
                    }.joined(separator: "\n")
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
