import Foundation
import SwiftUI
import AppKit
import LLMCostBarCore

/// Pairing-style flow for the claude.ai session cookie: paste from clipboard,
/// live-test against the real web API, and only then commit to the vault —
/// a cookie that never worked must never be stored. Mirrors PairingController's
/// phases and ClaudeConnectController's logging rules (silent failures banned).
@MainActor
final class ClaudeCookieController: ObservableObject {
    enum Phase: Equatable { case idle, testing, done, failed(String) }
    @Published var phase: Phase = .idle
    @Published var hasCookie: Bool = ClaudeSubscriptionProvider.vaultWebSession() != nil

    private let keychain = KeychainStore()
    private let paths = AppPaths.resolve()
    /// Injected by the views so logging reuses StoreModel's open DB pool.
    var store: UsageStore?
    var onChanged: (() -> Void)?

    func pasteAndTest() {
        guard phase != .testing else { return }
        let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            phase = .failed("Clipboard is empty — copy the Cookie header value first")
            return
        }
        phase = .testing
        let session = ClaudeWebSession(cookie: raw)
        Task {
            do {
                // Live test without touching the vault; capture the org id the
                // probe discovers so the saved session skips bootstrap forever.
                let discovered = DiscoveredBox()
                let probe = ClaudeSubscriptionProvider(
                    credentials: StaticClaudeTokenSource(token: "unused"),
                    detect: { false },
                    webSession: { session },
                    saveWebSession: { discovered.value = $0 })
                let snap = try await probe.fetchSnapshot(now: Date())
                try keychain.setKey((discovered.value ?? session).encodedJSON,
                                    accountID: ClaudeWebSession.vaultKey)
                try? store?.registerSubscriptionSource(source: SubscriptionSource.claude)
                try? store?.clearSubscriptionStale(source: SubscriptionSource.claude)
                // Instant card: the verified snapshot is real data — don't make
                // the user wait for the daemon's next poll to see bars.
                try? store?.upsertSubscriptionSnapshot(snap)
                hasCookie = true
                phase = .done
                log("ok", "cookie: verified (\(snap.windows.count) windows) & saved to vault")
                requestSync()
                settleDone()
            } catch let e as ProviderError {
                let msg: String
                switch e {
                case .auth: msg = "claude.ai rejected the cookie — copy a fresh one and retry"
                case .decode: msg = "unexpected claude.ai response — copy the FULL Cookie header and retry"
                default: msg = "network error — check your connection and retry"
                }
                phase = .failed(msg)
                log(e.errorClass, "cookie test failed: \(String(describing: e).prefix(200))")
            } catch {
                phase = .failed("network error — check your connection and retry")
                log("transient", "cookie test failed: \(String(describing: error).prefix(200))")
            }
        }
    }

    func removeCookie() {
        try? keychain.deleteKey(accountID: ClaudeWebSession.vaultKey)
        hasCookie = false
        phase = .idle
        log("ok", "cookie: removed from vault — falling back to Claude Code sign-in")
        requestSync()
    }

    final class DiscoveredBox: @unchecked Sendable { var value: ClaudeWebSession? }

    /// Success shows briefly, then returns to idle so a much later failure
    /// doesn't sit next to a stale "Saved ✓".
    private func settleDone() {
        Task {
            try? await Task.sleep(for: .seconds(30))
            if self.phase == .done { self.phase = .idle }
        }
    }

    private func requestSync() {
        try? Data().write(to: paths.syncRequest)
        onChanged?()
    }

    private func log(_ errorClass: String, _ message: String) {
        NSLog("LLMCostBar claude-cookie [%@]: %@", errorClass, message)
        try? store?.logSync(vendor: "claude-sub", accountID: "-", endpoint: "cookie",
                            httpStatus: nil, errorClass: errorClass, message: message, snippet: nil)
    }
}
