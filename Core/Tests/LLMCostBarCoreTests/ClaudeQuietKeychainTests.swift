import XCTest
@testable import LLMCostBarCore

final class ClaudeOAuthCacheTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-07-21T10:00:00Z")!
    // Claude Code's blob stores expiresAt in epoch milliseconds.
    let blob = #"{"claudeAiOauth":{"accessToken":"tok-1","refreshToken":"SECRET-rt","expiresAt":1789000000000,"subscriptionType":"max"}}"#

    func testParsesBlobFields() {
        let cache = ClaudeOAuthCache(blob: Data(blob.utf8))
        XCTAssertEqual(cache?.accessToken, "tok-1")
        XCTAssertEqual(cache?.expiresAt, Date(timeIntervalSince1970: 1_789_000_000))
        XCTAssertEqual(cache?.subscriptionType, "max")
    }

    func testRejectsBlobWithoutToken() {
        XCTAssertNil(ClaudeOAuthCache(blob: Data(#"{"mcpOAuth":{}}"#.utf8)))
        XCTAssertNil(ClaudeOAuthCache(blob: Data("<html>".utf8)))
        XCTAssertNil(ClaudeOAuthCache(blob: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)))
    }

    func testNeverStoresRefreshToken() {
        let json = ClaudeOAuthCache(blob: Data(blob.utf8))!.encodedJSON
        XCTAssertFalse(json.contains("SECRET-rt"))
        XCTAssertFalse(json.contains("refreshToken"))
    }

    func testFreshness() {
        func cache(expiresAt: Date?) -> ClaudeOAuthCache {
            ClaudeOAuthCache(accessToken: "t", expiresAt: expiresAt, subscriptionType: nil)
        }
        XCTAssertTrue(cache(expiresAt: now.addingTimeInterval(3600)).isFresh(now: now))
        XCTAssertFalse(cache(expiresAt: now.addingTimeInterval(-1)).isFresh(now: now))
        // Within the safety margin counts as expired: don't start a request that
        // will die mid-flight on a token about to lapse.
        XCTAssertFalse(cache(expiresAt: now.addingTimeInterval(30)).isFresh(now: now))
        // Blob without expiry: assume usable, let a 401 correct us.
        XCTAssertTrue(cache(expiresAt: nil).isFresh(now: now))
    }

    func testVaultCodecRoundtrip() {
        let cache = ClaudeOAuthCache(blob: Data(blob.utf8))!
        XCTAssertEqual(ClaudeOAuthCache.decode(cache.encodedJSON), cache)
        XCTAssertNil(ClaudeOAuthCache.decode("not json"))
    }
}

/// Deterministic resolver harness: dictionary-backed vault, scripted probe.
final class ResolverHarness: @unchecked Sendable {
    var vault: [String: String] = [:]
    var probeResult: ClaudeBlobResult = .denied("keychain: interaction not allowed")
    var probeCount = 0
    let now = ISO8601DateFormatter().date(from: "2026-07-21T10:00:00Z")!

    func blobJSON(token: String, expiresAtMs: Int64? = nil, plan: String = "max") -> String {
        let exp = expiresAtMs.map { ",\"expiresAt\":\($0)" } ?? ""
        return #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"rt"\#(exp),"subscriptionType":"\#(plan)"}}"#
    }

    lazy var resolver = ClaudeTokenResolver(
        getVault: { [self] key in vault[key] },
        setVault: { [self] key, value in vault[key] = value },
        deleteVault: { [self] key in vault[key] = nil },
        probeBlob: { [self] in probeCount += 1; return probeResult },
        now: { [self] in now })

    var futureMs: Int64 { Int64(now.addingTimeInterval(3600).timeIntervalSince1970) * 1000 }
    var pastMs: Int64 { Int64(now.addingTimeInterval(-3600).timeIntervalSince1970) * 1000 }

    func seedCache(token: String, expiresAtMs: Int64) {
        vault[ClaudeTokenResolver.cacheVaultKey] =
            ClaudeOAuthCache(blob: Data(blobJSON(token: token, expiresAtMs: expiresAtMs).utf8))!.encodedJSON
    }
}

final class ClaudeTokenResolverTests: XCTestCase {

    func testManualTokenTakesPrecedenceOverEverything() {
        let h = ResolverHarness()
        h.vault[ClaudeTokenResolver.manualTokenVaultKey] = "sk-ant-oat-manual"
        h.seedCache(token: "tok-cache", expiresAtMs: h.futureMs)
        guard case .found(let t) = h.resolver.resolve() else { return XCTFail("expected token") }
        XCTAssertEqual(t.accessToken, "sk-ant-oat-manual")
        XCTAssertEqual(t.source, .manualToken)
        XCTAssertEqual(h.probeCount, 0)   // never touches the foreign keychain item
    }

    func testFreshCacheUsedWithoutProbing() {
        let h = ResolverHarness()
        h.seedCache(token: "tok-cache", expiresAtMs: h.futureMs)
        guard case .found(let t) = h.resolver.resolve() else { return XCTFail("expected token") }
        XCTAssertEqual(t.accessToken, "tok-cache")
        XCTAssertEqual(t.source, .cache)
        XCTAssertEqual(t.subscriptionType, "max")
        XCTAssertEqual(h.probeCount, 0)
    }

    func testExpiredCacheSilentlyRefreshedByProbe() {
        let h = ResolverHarness()
        h.seedCache(token: "tok-old", expiresAtMs: h.pastMs)
        h.probeResult = .data(Data(h.blobJSON(token: "tok-new", expiresAtMs: h.futureMs).utf8))
        guard case .found(let t) = h.resolver.resolve() else { return XCTFail("expected token") }
        XCTAssertEqual(t.accessToken, "tok-new")
        XCTAssertEqual(h.probeCount, 1)
        // cache rewritten so the next poll doesn't probe again
        XCTAssertEqual(ClaudeOAuthCache.decode(h.vault[ClaudeTokenResolver.cacheVaultKey] ?? "")?.accessToken, "tok-new")
    }

    func testExpiredCacheAndBlockedProbeMeansReconnect() {
        let h = ResolverHarness()
        h.seedCache(token: "tok-old", expiresAtMs: h.pastMs)
        h.probeResult = .denied("keychain: interaction not allowed")
        XCTAssertEqual(h.resolver.resolve(), .reconnectNeeded)
    }

    func testNoCacheProbeSuccessSeedsCache() {
        // Upgrade path from ≤1.3.8: llmcostd may still hold a valid grant —
        // one silent probe converts it into a vault cache, zero user action.
        let h = ResolverHarness()
        h.probeResult = .data(Data(h.blobJSON(token: "tok-seed", expiresAtMs: h.futureMs).utf8))
        guard case .found(let t) = h.resolver.resolve() else { return XCTFail("expected token") }
        XCTAssertEqual(t.accessToken, "tok-seed")
        XCTAssertNotNil(h.vault[ClaudeTokenResolver.cacheVaultKey])
    }

    func testNoCacheProbeNotFoundMeansSignedOut() {
        let h = ResolverHarness()
        h.probeResult = .notFound
        XCTAssertEqual(h.resolver.resolve(), .signedOut)
    }

    func testNoCacheBlockedProbeMeansReconnect() {
        let h = ResolverHarness()
        XCTAssertEqual(h.resolver.resolve(), .reconnectNeeded)
    }

    func testGarbageProbeBlobIsInvalid() {
        let h = ResolverHarness()
        h.probeResult = .data(Data("<html>".utf8))
        guard case .invalid = h.resolver.resolve() else { return XCTFail("expected invalid") }
    }

    func testAfter401ManualTokenIsKeptAndReasonSaysSetupToken() {
        let h = ResolverHarness()
        h.vault[ClaudeTokenResolver.manualTokenVaultKey] = "sk-ant-oat-manual"
        let (retry, reason) = h.resolver.after401(failedToken: "sk-ant-oat-manual", source: .manualToken)
        XCTAssertNil(retry)
        XCTAssertTrue(reason.contains("setup-token"))
        XCTAssertEqual(h.vault[ClaudeTokenResolver.manualTokenVaultKey], "sk-ant-oat-manual")
        XCTAssertEqual(h.probeCount, 0)
    }

    func testAfter401CacheRotatedTokenRecoversSilently() {
        let h = ResolverHarness()
        h.seedCache(token: "tok-dead", expiresAtMs: h.futureMs)
        h.probeResult = .data(Data(h.blobJSON(token: "tok-rotated", expiresAtMs: h.futureMs).utf8))
        let (retry, _) = h.resolver.after401(failedToken: "tok-dead", source: .cache)
        XCTAssertEqual(retry?.accessToken, "tok-rotated")
        XCTAssertEqual(ClaudeOAuthCache.decode(h.vault[ClaudeTokenResolver.cacheVaultKey] ?? "")?.accessToken, "tok-rotated")
    }

    func testAfter401CacheSameTokenMeansReconnect() {
        let h = ResolverHarness()
        h.seedCache(token: "tok-dead", expiresAtMs: h.futureMs)
        h.probeResult = .data(Data(h.blobJSON(token: "tok-dead", expiresAtMs: h.futureMs).utf8))
        let (retry, reason) = h.resolver.after401(failedToken: "tok-dead", source: .cache)
        XCTAssertNil(retry)
        XCTAssertEqual(reason, ClaudeTokenResolver.reconnectReason)
        XCTAssertNil(h.vault[ClaudeTokenResolver.cacheVaultKey])   // dead cache dropped
    }

    func testStaticSourceServesFixedTokenAndNeverRetries() {
        let source = StaticClaudeTokenSource(token: "sk-ant-oat-pasted")
        guard case .found(let t) = source.resolve() else { return XCTFail("expected token") }
        XCTAssertEqual(t.accessToken, "sk-ant-oat-pasted")
        XCTAssertEqual(t.source, .manualToken)
        let (retry, reason) = source.after401(failedToken: "sk-ant-oat-pasted", source: .manualToken)
        XCTAssertNil(retry)
        XCTAssertTrue(reason.contains("setup-token"))
    }

    func testAfter401CacheBlockedProbeMeansReconnect() {
        let h = ResolverHarness()
        h.seedCache(token: "tok-dead", expiresAtMs: h.futureMs)
        h.probeResult = .denied("keychain: interaction not allowed")
        let (retry, reason) = h.resolver.after401(failedToken: "tok-dead", source: .cache)
        XCTAssertNil(retry)
        XCTAssertEqual(reason, ClaudeTokenResolver.reconnectReason)
        XCTAssertNil(h.vault[ClaudeTokenResolver.cacheVaultKey])
    }
}
