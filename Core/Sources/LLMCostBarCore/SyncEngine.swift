import Foundation
import os

/// One sync cycle over all active accounts. Owns the error taxonomy → DB state mapping:
/// transient → logged, data stays stale; auth → needs_reauth; success → upserts + last_sync_ok.
public final class SyncEngine: @unchecked Sendable {
    private let store: UsageStore
    private let paths: AppPaths
    private let providerFactory: (AccountRow, Credential) -> VendorProvider
    private let credentialLookup: (String) -> Credential?
    private let sleeper: @Sendable (Double) async -> Void
    private let log = Logger(subsystem: "com.mikeb.llmcostbar", category: "sync")

    public init(store: UsageStore, paths: AppPaths,
                providerFactory: @escaping (AccountRow, Credential) -> VendorProvider,
                credentialLookup: @escaping (String) -> Credential?,
                sleeper: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.store = store; self.paths = paths
        self.providerFactory = providerFactory; self.credentialLookup = credentialLookup
        self.sleeper = sleeper
    }

    /// Default factory for production: routes by vendor id.
    public static func defaultProviderFactory(account: AccountRow, credential: Credential) -> VendorProvider {
        switch account.vendor {
        default: OpenRouterProvider(accountID: account.id, credential: credential)
        }
    }

    public func syncAll() async {
        let accounts = (try? store.accounts()) ?? []
        for account in accounts {
            await sync(account)
        }
        try? Data().write(to: paths.heartbeat)   // touch: mtime is the heartbeat
    }

    private func sync(_ account: AccountRow) async {
        guard let cred = credentialLookup(account.id) else {
            log.error("no credential for \(account.id, privacy: .public)")
            try? store.setNeedsReauth(accountID: account.id, value: true)
            try? store.logSync(vendor: account.vendor, accountID: account.id, endpoint: "-",
                               httpStatus: nil, errorClass: "auth",
                               message: "no credential in keychain", snippet: nil)
            return
        }
        let provider = providerFactory(account, cred)
        do {
            let usage = try await withRetry(sleeper: sleeper) { try await provider.fetchUsage(sinceDaysAgo: 35, now: Date()) }
            try store.upsertUsage(usage)
            if let balance = try await withRetry(sleeper: sleeper, { try await provider.fetchBalance() }) {
                try store.upsertBalance(vendor: account.vendor, accountID: account.id,
                                        balanceUSD: balance.balanceUSD)
            }
            try store.markSyncOK(accountID: account.id)
            try store.logSync(vendor: account.vendor, accountID: account.id, endpoint: "sync",
                              httpStatus: 200, errorClass: "ok",
                              message: "\(usage.count) usage rows", snippet: nil)
            log.info("synced \(account.id, privacy: .public): \(usage.count) rows")
        } catch let e as ProviderError {
            handle(e, account: account)
        } catch {
            handle(.transient(String(describing: error)), account: account)
        }
    }

    private func handle(_ e: ProviderError, account: AccountRow) {
        var status: Int? = nil
        var message = ""
        var snippet: String? = nil
        switch e {
        case .transient(let m): message = m
        case .auth(let s, let snip):
            status = s; message = "auth failure"; snippet = snip
            try? store.setNeedsReauth(accountID: account.id, value: true)
        case .http(let s, let snip): status = s; message = "unexpected status"; snippet = snip
        case .decode(let m): message = m
        }
        log.error("sync \(account.id, privacy: .public) failed [\(e.errorClass, privacy: .public)]: \(message, privacy: .public)")
        try? store.logSync(vendor: account.vendor, accountID: account.id, endpoint: "sync",
                           httpStatus: status, errorClass: e.errorClass, message: message, snippet: snippet)
    }
}
