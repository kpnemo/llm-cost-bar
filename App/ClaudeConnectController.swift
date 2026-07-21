import Foundation
import SwiftUI
import AppKit
import LLMCostBarCore

/// The ONLY place an interactive read of Claude Code's keychain item happens —
/// in the app process, strictly behind a user click (Connect/Reconnect). The
/// fetched token is cached in our own vault; the daemon reads the cache and
/// never prompts. A denial simply parks here until the next click: nothing in
/// the background ever retries interactively.
@MainActor
final class ClaudeConnectController: ObservableObject {
    enum Phase: Equatable { case idle, connecting, testingToken, connected, failed(String) }
    @Published var phase: Phase = .idle
    @Published var setupTokenPresent = false

    private let keychain = KeychainStore()
    private let paths = AppPaths.resolve()
    /// Injected by the views so logging reuses StoreModel's open DB pool.
    var store: UsageStore?
    var onChanged: (() -> Void)?

    func refreshTokenPresence() {
        setupTokenPresent = ((try? keychain.getKey(
            accountID: ClaudeTokenResolver.manualTokenVaultKey)) ?? nil) != nil
    }

    /// Connect/Reconnect click: one interactive keychain read, off the main
    /// thread (the consent dialog blocks the calling thread).
    func connect() {
        guard phase != .connecting else { return }
        phase = .connecting
        Task.detached {
            let result = ClaudeCodeCredentials.readBlob(ui: .interactive)
            await MainActor.run { self.finishConnect(result) }
        }
    }

    private func finishConnect(_ result: ClaudeBlobResult) {
        switch result {
        case .data(let blob):
            guard let cache = ClaudeOAuthCache(blob: blob) else {
                phase = .failed("Claude Code's sign-in data didn't parse — update Claude Code, run it once, and retry")
                logConnect(errorClass: "decode", message: "connect: credential blob didn't parse")
                return
            }
            do {
                try keychain.setKey(cache.encodedJSON, accountID: ClaudeTokenResolver.cacheVaultKey)
                requestSync()
                settleConnected()
                logConnect(errorClass: "ok", message: "connect: Claude token cached in vault")
            } catch {
                phase = .failed("couldn't save to Keychain — see Diagnostics")
                logConnect(errorClass: "auth", message: "connect: vault write failed: \(error)")
            }
        case .notFound:
            phase = .failed("Claude Code isn't signed in on this Mac — run `claude` in Terminal once, then retry")
            logConnect(errorClass: "auth", message: "connect: no Claude Code credentials found")
        case .denied:
            phase = .failed("macOS didn't grant access — click again and choose “Allow”")
            logConnect(errorClass: "auth", message: "connect: keychain access denied")
        }
    }

    /// Zero-prompt path: validate a `claude setup-token` from the clipboard
    /// against the live usage endpoint BEFORE storing it — a token kind the
    /// endpoint rejects must fail here visibly, not silently in the daemon.
    func pasteSetupToken() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            phase = .failed("Clipboard is empty — copy the token first, then click again")
            return
        }
        guard raw.hasPrefix("sk-ant-oat") else {
            // Clipboard content is never echoed anywhere — it may be a password.
            phase = .failed("Clipboard doesn't contain a setup-token (sk-ant-oat…) — run `claude setup-token` and copy its output")
            logConnect(errorClass: "pairing", message: "setup-token paste rejected: not an sk-ant-oat token")
            return
        }
        phase = .testingToken
        Task {
            let probe = ClaudeSubscriptionProvider(credentials: StaticClaudeTokenSource(token: raw))
            do {
                _ = try await probe.fetchSnapshot(now: Date())
                try keychain.setKey(raw, accountID: ClaudeTokenResolver.manualTokenVaultKey)
                setupTokenPresent = true
                requestSync()
                settleConnected()
                logConnect(errorClass: "ok", message: "setup-token verified and stored")
            } catch let e as ProviderError {
                let msg: String
                switch e {
                case .auth: msg = "Token rejected by Anthropic — setup-tokens may not be accepted for usage; use Connect instead"
                case .transient: msg = "Network problem while testing the token — try again"
                default: msg = "Token test failed (\(e.errorClass)) — see Diagnostics"
                }
                phase = .failed(msg)
                logConnect(errorClass: e.errorClass, message: "setup-token test failed: \(String(String(describing: e).prefix(200)))")
            } catch {
                phase = .failed("Token test failed — see Diagnostics")
                logConnect(errorClass: "transient", message: "setup-token test failed: \(String(String(describing: error).prefix(200)))")
            }
        }
    }

    func removeSetupToken() {
        try? keychain.deleteKey(accountID: ClaudeTokenResolver.manualTokenVaultKey)
        setupTokenPresent = false
        phase = .idle
        requestSync()   // daemon falls back to the cache / no-UI probe
        logConnect(errorClass: "ok", message: "setup-token removed")
    }

    /// Success is shown briefly, then the phase returns to idle — otherwise a
    /// LATER staleness would resurface a card still claiming "connected ✓".
    private func settleConnected() {
        phase = .connected
        Task {
            try? await Task.sleep(for: .seconds(8))
            if self.phase == .connected { self.phase = .idle }
        }
    }

    private func requestSync() {
        try? Data().write(to: paths.syncRequest)
        onChanged?()
    }

    /// Every connect attempt lands in sync_log (Diagnostics) — same rule as
    /// pairing: silent failures are banned.
    private func logConnect(errorClass: String, message: String) {
        NSLog("LLMCostBar claude-connect [%@]: %@", errorClass, message)
        try? store?.logSync(vendor: "claude-sub", accountID: "-", endpoint: "connect",
                            httpStatus: nil, errorClass: errorClass, message: message, snippet: nil)
    }
}
