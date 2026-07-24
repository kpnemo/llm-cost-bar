import XCTest
@testable import LLMCostBarCore

/// Cookie-based claude.ai web path (ClaudeUsageBar approach). Fixture shapes
/// recorded from claude.ai's internal web API via the ClaudeUsageBar project.
final class ClaudeWebUsageTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-07-24T10:00:00Z")!

    // GET claude.ai/api/organizations/{org}/usage
    let webUsageJSON = #"""
    {"five_hour":{"utilization":42.0,"resets_at":"2026-07-24T16:00:00Z"},
     "seven_day":{"utilization":61.0,"resets_at":"2026-07-28T09:00:00Z"},
     "seven_day_sonnet":{"utilization":7.0,"resets_at":"2026-07-28T09:00:00Z"},
     "limits":[
       {"scope":{"model":{"display_name":"Fable"}},"percent":23,"resets_at":"2026-07-28T09:00:00Z"},
       {"scope":{"model":{"display_name":"Sonnet"}},"percent":99,"resets_at":"2026-07-28T09:00:00Z"},
       {"scope":{"other":true},"percent":5}
     ]}
    """#
    // GET .../overage_spend_limit
    let overageJSON = #"""
    {"used_credits":1234,"monthly_credit_limit":5000,"currency":"USD",
     "disabled_until":"2026-08-01T00:00:00Z"}
    """#
    // GET .../prepaid/credits — no `amount`, tranches fallback
    let prepaidTranchesJSON = #"""
    {"currency":"USD",
     "tranches":[{"remaining_amount_minor_units":300}],
     "promo_tranches":[{"remaining_amount_minor_units":200}]}
    """#
    // GET claude.ai/api/bootstrap
    let bootstrapJSON = #"{"account":{"lastActiveOrgId":"org-boot-1"}}"#

    // MARK: session

    func testNormalizeWrapsBareSessionKeyAndKeepsFullCookie() {
        XCTAssertEqual(ClaudeWebSession(cookie: " sk-ant-sid01-abc ").cookie,
                       "sessionKey=sk-ant-sid01-abc")
        let full = "anthropic-device-id=d1; sessionKey=sk-ant-sid01-abc; lastActiveOrg=org-9"
        XCTAssertEqual(ClaudeWebSession(cookie: full).cookie, full)
    }

    func testOrgIDFromCookie() {
        XCTAssertEqual(ClaudeWebSession.orgID(
            fromCookie: "a=1; lastActiveOrg=org-42; b=2"), "org-42")
        XCTAssertNil(ClaudeWebSession.orgID(fromCookie: "sessionKey=sk-1"))
        XCTAssertNil(ClaudeWebSession.orgID(fromCookie: "lastActiveOrg="))
    }

    func testSessionVaultCodecRoundtrip() {
        let s = ClaudeWebSession(cookie: "sessionKey=sk-1", orgID: "org-7")
        XCTAssertEqual(ClaudeWebSession.decode(s.encodedJSON), s)
        XCTAssertNil(ClaudeWebSession.decode("not json"))
    }

    // MARK: parsers

    func testParseUsageTopLevelWindowsAndModelLimits() throws {
        let windows = try ClaudeWebClient.parseUsage(Data(webUsageJSON.utf8))
        XCTAssertEqual(windows.map(\.windowID),
                       ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_fable"])
        // The Sonnet limits entry collides with the top-level window → skipped,
        // the scope-less entry has no model → skipped.
        let fable = windows.first { $0.windowID == "seven_day_fable" }
        XCTAssertEqual(fable?.usedPercent, 23)
        XCTAssertEqual(fable?.resetsAt, ISO8601DateFormatter().date(from: "2026-07-28T09:00:00Z"))
        XCTAssertEqual(fable.map { SubscriptionWindow(windowID: $0.windowID, usedPercent: 0).label },
                       "7-day Fable")
    }

    func testParseUsageEmptyThrowsDecode() {
        XCTAssertThrowsError(try ClaudeWebClient.parseUsage(Data("{}".utf8)))
        XCTAssertThrowsError(try ClaudeWebClient.parseUsage(Data("<html>".utf8)))
    }

    func testParseOverage() {
        let o = ClaudeWebClient.parseOverage(Data(overageJSON.utf8))
        XCTAssertEqual(o?.spentMinor, 1234)
        XCTAssertEqual(o?.limitMinor, 5000)
        XCTAssertEqual(o?.currency, "USD")
        XCTAssertEqual(o?.resetsAt, ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
    }

    func testParseCreditsAmountAndTranchesFallback() {
        XCTAssertEqual(ClaudeWebClient.parseCredits(Data(#"{"amount":150,"currency":"EUR"}"#.utf8))?.freeMinor, 150)
        let p = ClaudeWebClient.parseCredits(Data(prepaidTranchesJSON.utf8))
        XCTAssertEqual(p?.freeMinor, 500)   // 300 + 200
        XCTAssertNil(ClaudeWebClient.parseCredits(Data("{}".utf8)))
    }

    func testParseBootstrapOrgID() {
        XCTAssertEqual(ClaudeWebClient.parseBootstrapOrgID(Data(bootstrapJSON.utf8)), "org-boot-1")
        XCTAssertNil(ClaudeWebClient.parseBootstrapOrgID(Data("{}".utf8)))
    }

    // MARK: provider web path

    func makeWebProvider(_ http: any HTTPClient, session: ClaudeWebSession,
                         saved: SavedBox = SavedBox()) -> ClaudeSubscriptionProvider {
        ClaudeSubscriptionProvider(
            http: http,
            credentials: StaticClaudeTokenSource(token: "must-not-be-used"),
            detect: { false },
            webSession: { session },
            saveWebSession: { saved.value = $0 })
    }

    final class SavedBox: @unchecked Sendable { var value: ClaudeWebSession? }

    func testWebPathUsesCookieOrgAndSendsBrowserHeaders() async throws {
        let http = FakeHTTP()
        http.responses["/api/organizations/org-42/usage"] = (webUsageJSON, 200)
        http.responses["/api/organizations/org-42/overage_spend_limit"] = (overageJSON, 200)
        http.responses["/api/organizations/org-42/prepaid/credits"] = (prepaidTranchesJSON, 200)
        let cookie = "sessionKey=sk-1; lastActiveOrg=org-42"
        let saved = SavedBox()
        let snap = try await makeWebProvider(http, session: ClaudeWebSession(cookie: cookie),
                                             saved: saved).fetchSnapshot(now: now)
        XCTAssertEqual(snap.origin, "web")
        XCTAssertEqual(snap.windows.count, 4)
        XCTAssertEqual(snap.credit?.spentMinor, 1234)
        XCTAssertEqual(snap.credit?.limitMinor, 5000)
        XCTAssertEqual(snap.credit?.freeCreditsMinor, 500)
        XCTAssertEqual(http.recordedHeaders["Cookie"], cookie)
        XCTAssertEqual(http.recordedHeaders["Origin"], "https://claude.ai")
        XCTAssertEqual(http.recordedHeaders["User-Agent"]?.contains("Mozilla/5.0"), true)
        // org came straight from the cookie → persisted for later polls
        XCTAssertEqual(saved.value?.orgID, "org-42")
    }

    func testWebPathFallsBackToBootstrapForOrgID() async throws {
        let http = FakeHTTP()
        http.responses["/api/bootstrap"] = (bootstrapJSON, 200)
        http.responses["/api/organizations/org-boot-1/usage"] = (webUsageJSON, 200)
        let saved = SavedBox()
        let snap = try await makeWebProvider(http, session: ClaudeWebSession(cookie: "sessionKey=sk-1"),
                                             saved: saved).fetchSnapshot(now: now)
        XCTAssertEqual(snap.windows.isEmpty, false)
        XCTAssertNil(snap.credit)   // money endpoints unstubbed → additive, non-fatal
        XCTAssertEqual(saved.value?.orgID, "org-boot-1")
    }

    func testStoredOrgIDSkipsBootstrapAndIsNotReSaved() async throws {
        let http = FakeHTTP()
        http.responses["/api/organizations/org-7/usage"] = (webUsageJSON, 200)
        let saved = SavedBox()
        _ = try await makeWebProvider(http, session: ClaudeWebSession(cookie: "sessionKey=sk-1",
                                                                      orgID: "org-7"),
                                      saved: saved).fetchSnapshot(now: now)
        XCTAssertNil(saved.value)
    }

    func testExpiredCookieSurfacesAsAuthWithActionableReason() async throws {
        for status in [401, 403] {
            let http = FakeHTTP()
            http.responses["/api/organizations/org-42/usage"] = (#"{"error":"unauthorized"}"#, status)
            do {
                _ = try await makeWebProvider(
                    http, session: ClaudeWebSession(cookie: "sessionKey=sk-dead; lastActiveOrg=org-42"))
                    .fetchSnapshot(now: now)
                XCTFail("expected auth error for \(status)")
            } catch let ProviderError.auth(s, reason) {
                XCTAssertEqual(s, status)
                XCTAssertEqual(reason, ClaudeWebSession.cookieExpiredReason)
            }
        }
    }

    func testCookiePresenceMakesSourceDetected() {
        let provider = ClaudeSubscriptionProvider(
            http: FakeHTTP(), credentials: StaticClaudeTokenSource(token: "t"),
            detect: { false }, webSession: { ClaudeWebSession(cookie: "sessionKey=sk-1") },
            saveWebSession: { _ in })
        XCTAssertTrue(provider.isDetected())
    }
}
