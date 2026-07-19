import Foundation
import SwiftUI
import AppKit
import LLMCostBarCore

@MainActor
final class PairingController: ObservableObject {
    enum State: Equatable { case idle, waitingForBrowser, exchanging, done, failed(String) }
    @Published var state: State = .idle
    var pendingVerifier: String?
    var pendingDisplayName: String = ""
    var reconnectAccountID: String?
    var onPaired: (() -> Void)?
    /// Optional shared store injected by SettingsView so pairing reuses StoreModel's
    /// already-open DatabasePool instead of opening a second one. Falls back to
    /// opening its own pool if unset (e.g. in previews/tests).
    var store: UsageStore?

    private let keychain = KeychainStore()
    private let paths = AppPaths.resolve()

    /// Step 1 of the flow: open the browser at the OpenRouter consent page.
    /// Pass reconnectAccountID to re-key an existing account instead of creating a new one.
    func startBrowserPairing(displayName: String, reconnectAccountID: String? = nil) {
        let pkce = PKCE.generate()
        pendingVerifier = pkce.verifier
        pendingDisplayName = displayName
        self.reconnectAccountID = reconnectAccountID
        state = .waitingForBrowser
        NSWorkspace.shared.open(OpenRouterPairing.authURL(pkce: pkce))
    }

    /// Step 2: browser redirected to llmcostbar://callback?code=… (routed via AppDelegate).
    func handleCallback(url: URL) {
        guard let code = OpenRouterPairing.code(fromCallback: url), let verifier = pendingVerifier else {
            state = .failed("callback missing code"); return
        }
        state = .exchanging
        Task {
            do {
                let key = try await OpenRouterPairing.exchange(code: code, verifier: verifier)
                try finishPairing(apiKey: key)
            } catch {
                state = .failed("key exchange failed: \(error)")
            }
        }
    }

    /// Fallback path: user pasted an API/provisioning key directly.
    func pasteKeyPairing(displayName: String, apiKey: String) {
        pendingDisplayName = displayName
        do { try finishPairing(apiKey: apiKey) }
        catch { state = .failed("saving key failed: \(error)") }
    }

    private func finishPairing(apiKey: String) throws {
        if let existingID = reconnectAccountID {
            try keychain.setKey(apiKey, accountID: existingID)   // re-key existing account
            reconnectAccountID = nil
        } else {
            let accountID = "openrouter-\(UUID().uuidString.prefix(8))"
            try keychain.setKey(apiKey, accountID: accountID)
            let usageStore: UsageStore
            if let store {
                usageStore = store
            } else {
                let pool = try Database.open(at: paths.database)
                usageStore = UsageStore(db: pool)
            }
            try usageStore.addAccount(id: accountID, vendor: "openrouter",
                                      displayName: pendingDisplayName.isEmpty ? "personal" : pendingDisplayName)
        }
        try? Data().write(to: paths.syncRequest)     // daemon syncs within ~5 s
        pendingVerifier = nil
        state = .done
        onPaired?()
    }
}
