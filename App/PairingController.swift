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
    /// Only meaningful while `state == .waitingForBrowser`/`.exchanging` for a browser
    /// flow started with a reconnect target. Never read directly by finishPairing —
    /// handleCallback captures it into a local before the flow proceeds, and
    /// pasteKeyPairing always finalizes with an explicit `nil` regardless of this
    /// value, so a stray/abandoned browser flow can never leak its target into a
    /// paste-key finalization.
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
    /// Starting a new flow always discards any prior (abandoned) flow's pending state.
    func startBrowserPairing(displayName: String, reconnectAccountID: String? = nil) {
        let pkce = PKCE.generate()
        pendingVerifier = pkce.verifier
        pendingDisplayName = displayName
        self.reconnectAccountID = reconnectAccountID
        state = .waitingForBrowser
        NSWorkspace.shared.open(OpenRouterPairing.authURL(pkce: pkce))
    }

    /// Step 2: browser redirected to llmcostbar://callback?code=… (routed via AppDelegate).
    /// Re-entrancy/stray-callback guard: only a flow actively waiting for the browser
    /// may be completed here. A duplicate delivery, or a callback arriving after the
    /// flow already moved on (exchanging/done/failed/idle), is silently ignored rather
    /// than surfacing a confusing error banner.
    func handleCallback(url: URL) {
        guard state == .waitingForBrowser else { return }
        guard let code = OpenRouterPairing.code(fromCallback: url), let verifier = pendingVerifier else {
            state = .failed("callback missing code"); return
        }
        // Capture and clear synchronously (before the `await` suspension point) so a
        // second callback delivered while this one is in flight fails the state guard
        // above instead of racing this flow's verifier/reconnect target.
        let displayName = pendingDisplayName
        let reconnectID = reconnectAccountID
        pendingVerifier = nil
        reconnectAccountID = nil
        state = .exchanging
        Task {
            do {
                let key = try await OpenRouterPairing.exchange(code: code, verifier: verifier)
                try finishPairing(apiKey: key, displayName: displayName, reconnectAccountID: reconnectID)
            } catch {
                state = .failed("key exchange failed: \(error)")
            }
        }
    }

    /// Fallback path: user pasted an API/provisioning key directly. Always creates/re-keys
    /// with no reconnect target — pasting is never used to complete a reconnect flow.
    func pasteKeyPairing(displayName: String, apiKey: String) {
        do { try finishPairing(apiKey: apiKey, displayName: displayName, reconnectAccountID: nil) }
        catch { state = .failed("saving key failed: \(error)") }
    }

    private func finishPairing(apiKey: String, displayName: String, reconnectAccountID: String?) throws {
        if let existingID = reconnectAccountID {
            try keychain.setKey(apiKey, accountID: existingID)   // re-key existing account
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
                                      displayName: displayName.isEmpty ? "personal" : displayName)
        }
        try? Data().write(to: paths.syncRequest)     // daemon syncs within ~5 s
        state = .done
        onPaired?()
    }
}
