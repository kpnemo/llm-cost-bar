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
    enum Phase: Equatable { case idle, connecting, connected, failed(String) }
    @Published var phase: Phase = .idle

    private let keychain = KeychainStore()
    private let paths = AppPaths.resolve()
    /// Injected by the views so logging reuses StoreModel's open DB pool.
    var store: UsageStore?
    var onChanged: (() -> Void)?

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
