import Foundation

/// Snapshot of Claude Code's OAuth credential cached in OUR keychain vault.
/// Deliberately excludes the refresh token: we must never be in a position to
/// use it (rotating it would log the user out of Claude Code), so we never
/// hold it. expiresAt arrives as epoch milliseconds in the source blob.
public struct ClaudeOAuthCache: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Parse from Claude Code's raw credential blob ({"claudeAiOauth":{...}}).
    public init?(blob: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        self.init(accessToken: token,
                  expiresAt: expiresMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                  subscriptionType: oauth["subscriptionType"] as? String)
    }

    /// Usable now? The margin keeps us from starting a request on a token that
    /// lapses mid-flight; no expiry recorded → assume usable, a 401 corrects us.
    public func isFresh(now: Date, margin: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > margin
    }

    // MARK: vault codec (the vault stores strings)

    public var encodedJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }

    public static func decode(_ json: String) -> ClaudeOAuthCache? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(ClaudeOAuthCache.self, from: Data(json.utf8))
    }
}

/// A resolved token plus where it came from — the 401 recovery path differs
/// per source (manual tokens are replaced by the user, cached ones re-probed).
public struct ResolvedClaudeToken: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case manualToken, cache }
    public let accessToken: String
    public let subscriptionType: String?
    public let source: Source

    public init(accessToken: String, subscriptionType: String?, source: Source) {
        self.accessToken = accessToken
        self.subscriptionType = subscriptionType
        self.source = source
    }
}

public enum ClaudeTokenResolution: Equatable, Sendable {
    case found(ResolvedClaudeToken)
    /// Claude Code isn't signed in on this Mac (no keychain item, no file).
    case signedOut
    /// A usable token exists only behind a prompt — surface a click-gated
    /// reconnect instead; the background NEVER prompts.
    case reconnectNeeded
    /// Credential blob exists but doesn't parse.
    case invalid(String)
}

/// How ClaudeSubscriptionProvider obtains tokens. The daemon's implementation
/// (ClaudeTokenResolver) is non-interactive by construction.
public protocol ClaudeCredentialSource: Sendable {
    func resolve() -> ClaudeTokenResolution
    /// Feedback after an HTTP 401. Returns a replacement token to retry once
    /// with (silent recovery), or nil plus the stale reason to surface.
    func after401(failedToken: String, source: ResolvedClaudeToken.Source)
        -> (retry: ResolvedClaudeToken?, reason: String)
}

/// Fixed-token source: used by the app to live-test a pasted setup-token
/// before committing it to the vault. Never retries.
public struct StaticClaudeTokenSource: ClaudeCredentialSource {
    let token: String
    public init(token: String) { self.token = token }

    public func resolve() -> ClaudeTokenResolution {
        .found(ResolvedClaudeToken(accessToken: token, subscriptionType: nil, source: .manualToken))
    }

    public func after401(failedToken: String, source: ResolvedClaudeToken.Source)
    -> (retry: ResolvedClaudeToken?, reason: String) {
        (nil, ClaudeTokenResolver.setupTokenRejectedReason)
    }
}

/// The quiet path to a Claude token, in strict precedence order:
///   1. manual `claude setup-token` from the vault (zero-prompt, ~1 year)
///   2. vault-cached OAuth token while fresh
///   3. a NO-UI probe of Claude Code's keychain item — returns an error
///      instead of showing a dialog when consent is missing
/// Nothing here can ever present a keychain prompt; when all three fail the
/// result is `reconnectNeeded` and the app shows a click-gated Reconnect.
public struct ClaudeTokenResolver: ClaudeCredentialSource {
    public static let cacheVaultKey = "__claude_oauth_cache__"
    public static let manualTokenVaultKey = "__claude_setup_token__"
    /// Machine-checked by the app (shows the Reconnect button) AND shown raw
    /// in Settings — keep it human-readable.
    public static let reconnectReason = "needs reconnect — click Reconnect on the Claude card"
    public static let setupTokenRejectedReason =
        "setup-token rejected — run `claude setup-token` again, then re-paste it in Settings"

    private let getVault: @Sendable (String) -> String?
    private let setVault: @Sendable (String, String) -> Void
    private let deleteVault: @Sendable (String) -> Void
    private let probeBlob: @Sendable () -> ClaudeBlobResult
    private let now: @Sendable () -> Date

    public init(getVault: @escaping @Sendable (String) -> String?,
                setVault: @escaping @Sendable (String, String) -> Void,
                deleteVault: @escaping @Sendable (String) -> Void,
                probeBlob: @escaping @Sendable () -> ClaudeBlobResult,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.getVault = getVault
        self.setVault = setVault
        self.deleteVault = deleteVault
        self.probeBlob = probeBlob
        self.now = now
    }

    /// Production wiring: our vault + a no-UI keychain probe. Vault I/O never
    /// prompts (both binaries are ACL'd on our own item).
    public static func live(keychain: KeychainStore = KeychainStore()) -> ClaudeTokenResolver {
        ClaudeTokenResolver(
            getVault: { (try? keychain.getKey(accountID: $0)) ?? nil },
            setVault: { try? keychain.setKey($1, accountID: $0) },
            deleteVault: { try? keychain.deleteKey(accountID: $0) },
            probeBlob: { ClaudeCodeCredentials.readBlob(ui: .noPrompt) })
    }

    public func resolve() -> ClaudeTokenResolution {
        if let manual = getVault(Self.manualTokenVaultKey), !manual.isEmpty {
            return .found(ResolvedClaudeToken(accessToken: manual, subscriptionType: nil,
                                              source: .manualToken))
        }
        if let raw = getVault(Self.cacheVaultKey),
           let cache = ClaudeOAuthCache.decode(raw), cache.isFresh(now: now()) {
            return .found(ResolvedClaudeToken(accessToken: cache.accessToken,
                                              subscriptionType: cache.subscriptionType,
                                              source: .cache))
        }
        return probeIntoCache()
    }

    public func after401(failedToken: String, source: ResolvedClaudeToken.Source)
    -> (retry: ResolvedClaudeToken?, reason: String) {
        switch source {
        case .manualToken:
            // Kept in place: the user replaces it explicitly via Settings.
            return (nil, Self.setupTokenRejectedReason)
        case .cache:
            deleteVault(Self.cacheVaultKey)
            if case .found(let t) = probeIntoCache(), t.accessToken != failedToken {
                return (t, "")
            }
            deleteVault(Self.cacheVaultKey)   // probe may have re-cached the dead token
            return (nil, Self.reconnectReason)
        }
    }

    /// Silent no-UI read of Claude Code's item; success refreshes the vault
    /// cache so subsequent polls skip the probe entirely.
    private func probeIntoCache() -> ClaudeTokenResolution {
        switch probeBlob() {
        case .data(let blob):
            guard let cache = ClaudeOAuthCache(blob: blob) else {
                return .invalid("credential blob: no claudeAiOauth.accessToken")
            }
            setVault(Self.cacheVaultKey, cache.encodedJSON)
            return .found(ResolvedClaudeToken(accessToken: cache.accessToken,
                                              subscriptionType: cache.subscriptionType,
                                              source: .cache))
        case .notFound:
            return .signedOut
        case .denied:
            return .reconnectNeeded
        }
    }
}
