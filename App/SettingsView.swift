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
        }
    }
}

struct AccountsTab: View {
    @EnvironmentObject var model: StoreModel
    @EnvironmentObject var pairing: PairingController
    @State private var newName = "personal"
    @State private var pastedKey = ""
    @State private var showPasteField = false

    var body: some View {
        Form {
            Section("Connected accounts") {
                if model.accounts.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(model.accounts, id: \.id) { acc in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(acc.vendor.capitalized) — \(acc.displayName)")
                            Text(acc.needsReauth ? "⚠ reconnect needed"
                                 : (acc.lastSyncOK.map { "✓ connected · synced \($0)" } ?? "waiting for first sync"))
                                .font(.caption).foregroundStyle(acc.needsReauth ? .red : .secondary)
                        }
                        Spacer()
                        if acc.needsReauth {
                            Button("Reconnect") { pairing.startBrowserPairing(displayName: acc.displayName, reconnectAccountID: acc.id) }
                        }
                        Button("Remove", role: .destructive) {
                            try? model.store.removeAccount(id: acc.id)
                            try? KeychainStore().deleteKey(accountID: acc.id)
                            model.refresh()
                        }
                    }
                }
            }
            Section("Add OpenRouter account") {
                TextField("Name", text: $newName)
                HStack {
                    Button("Connect via browser") { pairing.startBrowserPairing(displayName: newName) }
                        .disabled(pairing.state == .waitingForBrowser || pairing.state == .exchanging)
                    Button("paste a key instead…") { showPasteField.toggle() }
                        .buttonStyle(.link)
                }
                if showPasteField {
                    SecureField("sk-or-v1-…", text: $pastedKey)
                    Button("Save key") { pairing.pasteKeyPairing(displayName: newName, apiKey: pastedKey); pastedKey = "" }
                        .disabled(pastedKey.isEmpty)
                }
                pairingStatus
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.state {
        case .idle: EmptyView()
        case .waitingForBrowser: Label("Waiting for browser approval…", systemImage: "safari")
        case .exchanging: Label("Exchanging code…", systemImage: "arrow.triangle.2.circlepath")
        case .done: Label("Connected — first sync running", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let msg): Label(msg, systemImage: "xmark.circle").foregroundStyle(.red)
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
                Text("Month to date").tag(MenuBarDisplay.monthToDate)
            }
            Picker("Refresh every", selection: $model.config.refreshMinutes) {
                ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
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
