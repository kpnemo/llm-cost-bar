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
    /// completePairing captures it into a local before the flow proceeds, and
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
    /// OpenRouter rejects custom URL-scheme callback_urls client-side (redirects to the
    /// homepage instead of the consent page), so pairing redirects to a real http
    /// loopback address instead of llmcostbar://. One server per in-flight browser flow.
    private var loopbackServer: LoopbackServer?

    /// Step 1 of the flow: start a local loopback callback listener and open the browser
    /// at the OpenRouter consent page pointed at it.
    /// Pass reconnectAccountID to re-key an existing account instead of creating a new one.
    /// Starting a new flow always discards any prior (abandoned) flow's pending state.
    func startBrowserPairing(displayName: String, reconnectAccountID: String? = nil) {
        let pkce = PKCE.generate()
        let server = LoopbackServer()
        do {
            try server.start { [weak self] code in
                Task { @MainActor in self?.completePairing(code: code) }
            }
        } catch {
            state = .failed("could not start local callback server: \(error)")
            return
        }

        loopbackServer = server
        pendingVerifier = pkce.verifier
        pendingDisplayName = displayName
        self.reconnectAccountID = reconnectAccountID
        state = .waitingForBrowser
        NSWorkspace.shared.open(OpenRouterPairing.authURL(pkce: pkce, callbackURL: server.callbackURL))
    }

    /// Legacy path: llmcostbar://callback URL scheme, still routed via AppDelegate in
    /// case a stale build/bookmark ever delivers one. Funnels into the same completion
    /// logic as the loopback server's callback.
    func handleCallback(url: URL) {
        guard state == .waitingForBrowser else { return }
        guard let code = OpenRouterPairing.code(fromCallback: url) else {
            state = .failed("callback missing code"); return
        }
        completePairing(code: code)
    }

    /// Shared completion path for both the loopback server and the legacy URL scheme.
    /// Re-entrancy/stray-callback guard: only a flow actively waiting for the browser
    /// may be completed here. A duplicate delivery, or a callback arriving after the
    /// flow already moved on (exchanging/done/failed/idle/cancelled), is silently
    /// ignored rather than surfacing a confusing error banner.
    private func completePairing(code: String) {
        guard state == .waitingForBrowser, let verifier = pendingVerifier else { return }
        // Capture and clear synchronously (before the `await` suspension point) so a
        // second callback delivered while this one is in flight fails the state guard
        // above instead of racing this flow's verifier/reconnect target.
        let displayName = pendingDisplayName
        let reconnectID = reconnectAccountID
        pendingVerifier = nil
        reconnectAccountID = nil
        loopbackServer?.stop()
        loopbackServer = nil
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

    /// Escape hatch: user gives up waiting for the browser (e.g. closed the tab, or
    /// changed their mind). Discards the abandoned flow's pending state so a callback
    /// that arrives later fails the `.waitingForBrowser` guard in completePairing and is
    /// ignored, and returns the Add-account UI to idle.
    func cancelPairing() {
        pendingVerifier = nil
        reconnectAccountID = nil
        loopbackServer?.stop()
        loopbackServer = nil
        state = .idle
    }

    /// Fallback path: user pasted an API/provisioning key directly. Always creates/re-keys
    /// with no reconnect target — pasting is never used to complete a reconnect flow.
    func pasteKeyPairing(displayName: String, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { state = .failed("key is empty"); return }
        do { try finishPairing(apiKey: key, displayName: displayName, reconnectAccountID: nil) }
        catch {
            state = .failed("saving key failed: \(error)")
            logPairing(errorClass: "pairing", message: "paste failed: \(error)")
        }
    }

    /// Primary onboarding path: read the management key from the clipboard (no text
    /// field — SecureField editability proved unreliable in the Settings scene), then
    /// live-test it against the real endpoints before storing anything. Only a key that
    /// can actually read activity gets saved — a regular API key fails the test with a
    /// pointed message instead of being stored and failing silently in the daemon.
    func addProviderFromClipboard(displayName: String) {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            state = .failed("Clipboard is empty — copy the management key first, then click again")
            return
        }
        guard raw.hasPrefix("sk-or-") else {
            state = .failed("Clipboard doesn't contain an OpenRouter key (should start with sk-or-…)")
            return
        }
        state = .exchanging   // rendered as "Testing connection…"
        Task {
            let provider = OpenRouterProvider(accountID: "probe", credential: Credential(apiKey: raw))
            do {
                _ = try await provider.fetchUsage(sinceDaysAgo: 2, now: Date())   // the call that needs a management key
                try finishPairing(apiKey: raw, displayName: displayName, reconnectAccountID: nil)
            } catch let e as ProviderError {
                let msg: String
                switch e {
                case .auth: msg = "Key rejected by OpenRouter — make sure you created a MANAGEMENT (provisioning) key, not a regular API key"
                case .transient: msg = "Network problem while testing — try again"
                default: msg = "Connection test failed (\(e.errorClass)) — see Diagnostics"
                }
                state = .failed(msg)
                logPairing(errorClass: "pairing", message: "probe failed: \(String(String(describing: e).prefix(120)))")
            } catch {
                state = .failed("Connection test failed — see Diagnostics")
                logPairing(errorClass: "pairing", message: "probe failed: \(String(String(describing: error).prefix(120)))")
            }
        }
    }

    private func finishPairing(apiKey: String, displayName: String, reconnectAccountID: String?) throws {
        if let existingID = reconnectAccountID {
            try keychain.setKey(apiKey, accountID: existingID)   // re-key existing account
            logPairing(errorClass: "ok", message: "re-keyed account \(existingID)")
        } else {
            let accountID = "openrouter-\(UUID().uuidString.prefix(8))"
            try keychain.setKey(apiKey, accountID: accountID)
            try pairingStore().addAccount(id: accountID, vendor: "openrouter",
                                          displayName: displayName.isEmpty ? "personal" : displayName)
            logPairing(errorClass: "ok", message: "added account \(accountID)")
        }
        try? Data().write(to: paths.syncRequest)     // daemon syncs within ~5 s
        state = .done
        onPaired?()
    }

    private func pairingStore() throws -> UsageStore {
        if let store { return store }
        let pool = try Database.open(at: paths.database)
        let fresh = UsageStore(db: pool)
        store = fresh
        return fresh
    }

    /// Every pairing outcome lands in sync_log so the Diagnostics tab shows it —
    /// a silent pairing failure cost us a debugging round once already.
    private func logPairing(errorClass: String, message: String) {
        NSLog("LLMCostBar pairing [%@]: %@", errorClass, message)
        try? (try? pairingStore())?.logSync(vendor: "openrouter", accountID: "-",
                                            endpoint: "pairing", httpStatus: nil,
                                            errorClass: errorClass, message: message, snippet: nil)
    }
}
