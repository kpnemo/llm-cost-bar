import XCTest
@testable import LLMCostBarCore

final class ClaudeSubscriptionProviderTests: XCTestCase {
    // Recorded shape of GET api.anthropic.com/api/oauth/usage (community-verified).
    let oauthUsageJSON = #"""
    {"five_hour":{"utilization":42.0,"resets_at":"2026-07-21T16:00:00Z"},
     "seven_day":{"utilization":61.0,"resets_at":"2026-07-24T09:00:00Z"},
     "seven_day_opus":{"utilization":87.0,"resets_at":"2026-07-24T09:00:00Z"},
     "seven_day_sonnet":{"utilization":1.0,"resets_at":"2026-07-24T09:00:00Z"},
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
    """#
    let oauthUsageNullOpusJSON = #"""
    {"five_hour":{"utilization":150.0,"resets_at":"2026-07-21T16:00:00Z"},
     "seven_day":{"utilization":13.0,"resets_at":"2026-07-24T09:00:00Z"},
     "seven_day_opus":null,"seven_day_sonnet":null}
    """#
    let now = ISO8601DateFormatter().date(from: "2026-07-21T10:00:00Z")!

    func makeProvider(_ http: FakeHTTP,
                      state: ClaudeCredentialState = .found(accessToken: "tok-abc", subscriptionType: "max_5x"))
    -> ClaudeSubscriptionProvider {
        ClaudeSubscriptionProvider(http: http, credentials: { state }, detect: { true })
    }

    func testParsesAllWindowsAndSendsLoadBearingHeaders() async throws {
        let http = FakeHTTP(); http.responses["/api/oauth/usage"] = (oauthUsageJSON, 200)
        let snap = try await makeProvider(http).fetchSnapshot(now: now)
        XCTAssertEqual(snap.source, "claude")
        XCTAssertEqual(snap.planType, "max_5x")
        XCTAssertEqual(snap.origin, "api")
        XCTAssertEqual(snap.windows.count, 4)
        let opus = snap.windows.first { $0.windowID == "seven_day_opus" }
        XCTAssertEqual(opus?.usedPercent, 87)
        XCTAssertEqual(opus?.resetsAt, ISO8601DateFormatter().date(from: "2026-07-24T09:00:00Z"))
        XCTAssertEqual(http.recordedHeaders["Authorization"], "Bearer tok-abc")
        XCTAssertEqual(http.recordedHeaders["anthropic-beta"], "oauth-2025-04-20")
        XCTAssertEqual(http.recordedHeaders["User-Agent"]?.hasPrefix("claude-code/"), true)
    }

    func testNullWindowsSkippedAndUtilizationClamped() async throws {
        let http = FakeHTTP(); http.responses["/api/oauth/usage"] = (oauthUsageNullOpusJSON, 200)
        let snap = try await makeProvider(http).fetchSnapshot(now: now)
        XCTAssertEqual(snap.windows.map(\.windowID), ["five_hour", "seven_day"])
        XCTAssertEqual(snap.windows[0].usedPercent, 100)   // 150 → clamped
    }

    func test401SurfacesAsAuthWithActionableReason() async throws {
        let http = FakeHTTP(); http.responses["/api/oauth/usage"] = (#"{"error":"expired"}"#, 401)
        do {
            _ = try await makeProvider(http).fetchSnapshot(now: now)
            XCTFail("expected auth error")
        } catch let ProviderError.auth(status, reason) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(reason.contains("Claude Code"))
        }
    }

    func testDeniedKeychainSurfacesAsAuthWithReason() async throws {
        let http = FakeHTTP()
        do {
            _ = try await makeProvider(http, state: .denied("grant llmcostd access — click Always Allow"))
                .fetchSnapshot(now: now)
            XCTFail("expected auth error")
        } catch let ProviderError.auth(_, reason) {
            XCTAssertTrue(reason.contains("Always Allow"))
        }
    }

    func testGarbageBodySurfacesAsDecode() async throws {
        let http = FakeHTTP(); http.responses["/api/oauth/usage"] = ("<html>", 200)
        do {
            _ = try await makeProvider(http).fetchSnapshot(now: now)
            XCTFail("expected decode error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "decode")
        }
    }

    func testCredentialBlobParsing() {
        let blob = #"{"claudeAiOauth":{"accessToken":"tok-1","refreshToken":"rt","expiresAt":1789000000000,"subscriptionType":"max"}}"#
        guard case .found(let token, let sub) = ClaudeCodeCredentials.parse(Data(blob.utf8)) else {
            return XCTFail("expected .found")
        }
        XCTAssertEqual(token, "tok-1")
        XCTAssertEqual(sub, "max")
        if case .invalid = ClaudeCodeCredentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8)) {} else {
            XCTFail("mcpOAuth-only blob must be invalid")
        }
    }
}

final class CodexSubscriptionProviderTests: XCTestCase {
    let whamUsageJSON = #"""
    {"plan_type":"plus",
     "rate_limit":{"primary_window":{"used_percent":12,"reset_at":1785061906,"limit_window_seconds":604800},
                   "secondary_window":{"used_percent":3,"reset_at":1784661906,"limit_window_seconds":18000}},
     "credits":{"has_credits":false}}
    """#
    let rolloutLine = #"""
    {"timestamp":"2026-07-20T08:30:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":34.5,"window_minutes":10080,"resets_at":1785061906},"secondary":null,"credits":{"has_credits":false},"plan_type":"prolite"}}}
    """#
    let authJSON = #"{"auth_mode":"chatgpt","tokens":{"access_token":"at-1","refresh_token":"rt-1","account_id":"acc-42"},"last_refresh":"2026-07-20T18:00:00Z"}"#
    let now = ISO8601DateFormatter().date(from: "2026-07-21T10:00:00Z")!

    func makeHome(auth: Bool, rollout: String? = nil, dayPath: String = "2026/07/20") throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        if auth {
            try Data(authJSON.utf8).write(to: home.appendingPathComponent("auth.json"))
        }
        if let rollout {
            let dir = home.appendingPathComponent("sessions/\(dayPath)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(rollout.utf8).write(to: dir.appendingPathComponent("rollout-1.jsonl"))
        }
        return home
    }

    func testAPIPathParsesWindowsAndSendsAccountHeader() async throws {
        let http = FakeHTTP(); http.responses["/wham/usage"] = (whamUsageJSON, 200)
        let home = try makeHome(auth: true)
        let snap = try await CodexSubscriptionProvider(http: http, home: home).fetchSnapshot(now: now)
        XCTAssertEqual(snap.origin, "api")
        XCTAssertEqual(snap.planType, "plus")
        XCTAssertEqual(snap.windows.count, 2)
        let primary = snap.windows.first { $0.windowID == "primary" }
        XCTAssertEqual(primary?.usedPercent, 12)
        XCTAssertEqual(primary?.windowMinutes, 10080)   // limit_window_seconds / 60
        XCTAssertEqual(primary?.resetsAt, Date(timeIntervalSince1970: 1785061906))
        XCTAssertEqual(http.recordedHeaders["ChatGPT-Account-Id"], "acc-42")
        XCTAssertEqual(http.recordedHeaders["Authorization"], "Bearer at-1")
    }

    func testNoAuthFallsBackToSessionJSONL() async throws {
        let home = try makeHome(auth: false, rollout: rolloutLine)
        let snap = try await CodexSubscriptionProvider(http: FakeHTTP(), home: home).fetchSnapshot(now: now)
        XCTAssertEqual(snap.origin, "jsonl")
        XCTAssertEqual(snap.planType, "prolite")
        XCTAssertEqual(snap.windows.map(\.windowID), ["primary"])   // secondary null → skipped
        XCTAssertEqual(snap.windows[0].usedPercent, 34.5)
        XCTAssertEqual(snap.observedAt, ISO8601DateFormatter().date(from: "2026-07-20T08:30:00Z"))
    }

    func testAPIFailureFallsBackToJSONL() async throws {
        let http = FakeHTTP(); http.responses["/wham/usage"] = ("oops", 500)
        let home = try makeHome(auth: true, rollout: rolloutLine)
        let snap = try await CodexSubscriptionProvider(http: http, home: home).fetchSnapshot(now: now)
        XCTAssertEqual(snap.origin, "jsonl")
    }

    func testAPIAuthFailureWithoutJSONLSurfacesAsAuth() async throws {
        let http = FakeHTTP(); http.responses["/wham/usage"] = (#"{"detail":"expired"}"#, 401)
        let home = try makeHome(auth: true)
        do {
            _ = try await CodexSubscriptionProvider(http: http, home: home).fetchSnapshot(now: now)
            XCTFail("expected auth error")
        } catch let ProviderError.auth(_, reason) {
            XCTAssertTrue(reason.contains("Codex"))
        }
    }

    func testNoDataAtAllIsTransient() async throws {
        let home = try makeHome(auth: false)
        do {
            _ = try await CodexSubscriptionProvider(http: FakeHTTP(), home: home).fetchSnapshot(now: now)
            XCTFail("expected transient error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "transient")
        }
    }

    func testNewestSessionFileWinsAcrossDayDirs() async throws {
        let home = try makeHome(auth: false, rollout: rolloutLine, dayPath: "2026/07/19")
        let newer = rolloutLine.replacingOccurrences(of: "34.5", with: "77.0")
            .replacingOccurrences(of: "2026-07-20T08:30:00Z", with: "2026-07-21T09:00:00Z")
        let dir = home.appendingPathComponent("sessions/2026/07/21")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("rollout-2.jsonl")
        try Data(newer.utf8).write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        let snap = try await CodexSubscriptionProvider(http: FakeHTTP(), home: home).fetchSnapshot(now: now)
        XCTAssertEqual(snap.windows[0].usedPercent, 77.0)
    }

    func testAuthJSONParsing() {
        let auth = CodexLocalState.parseAuth(Data(authJSON.utf8))
        XCTAssertEqual(auth?.accessToken, "at-1")
        XCTAssertEqual(auth?.accountID, "acc-42")
        XCTAssertNil(CodexLocalState.parseAuth(Data(#"{"auth_mode":"chatgpt"}"#.utf8)))
    }
}
