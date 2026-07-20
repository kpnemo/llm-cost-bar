import XCTest
@testable import LLMCostBarCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var responses: [String: (String, Int)] = [:]   // url substring → (body, status)
    func get(_ url: URL, bearer: String) async throws -> (Data, Int) {
        // Prefer the most specific (longest) matching key so a paginated URL
        // containing both "group_by=…" and "page=tok2" matches the page stub,
        // not the page-1 stub which is also a substring of the page-2 URL.
        var best: (String, Int)? = nil
        var bestLen = -1
        for (k, v) in responses where url.absoluteString.contains(k) && k.count > bestLen {
            best = v; bestLen = k.count
        }
        if let best { return (Data(best.0.utf8), best.1) }
        throw ProviderError.transient("no stub for \(url)")
    }
    func post(_ url: URL, json: [String: String]) async throws -> (Data, Int) {
        try await get(url, bearer: "")
    }
}

final class OpenRouterProviderTests: XCTestCase {
    let creditsJSON = #"{"data":{"total_credits":110.0,"total_usage":71.5}}"#
    let activityJSON = #"""
    {"data":[
      {"date":"2026-07-19 00:00:00","model":"anthropic/claude-sonnet-4","usage":1.40,"requests":10,"prompt_tokens":1000,"completion_tokens":500},
      {"date":"2026-07-19","model":"openai/gpt-5","usage":0.70,"requests":3,"prompt_tokens":200,"completion_tokens":100},
      {"date":"2026-07-01","model":"anthropic/claude-sonnet-4","usage":59.10,"requests":50,"prompt_tokens":9000,"completion_tokens":4000}
    ]}
    """#
    let keyJSON = #"{"data":{"label":"claude-code","usage":12.3}}"#

    func makeProvider(_ http: FakeHTTP) -> OpenRouterProvider {
        OpenRouterProvider(accountID: "acc1", credential: Credential(apiKey: "sk-or-test"), http: http)
    }

    func testFetchBalanceParsesCreditsMinusUsage() async throws {
        let http = FakeHTTP(); http.responses["/credits"] = (creditsJSON, 200)
        let balance = try await makeProvider(http).fetchBalance()
        XCTAssertEqual(balance?.balanceUSD ?? 0, 38.5, accuracy: 0.001)
    }

    func testFetchUsageNormalizesRows() async throws {
        let http = FakeHTTP()
        http.responses["/activity"] = (activityJSON, 200)
        http.responses["/key"] = (keyJSON, 200)
        let fixedNow = ISO8601DateFormatter().date(from: "2026-07-19T12:00:00Z")!
        let records = try await makeProvider(http).fetchUsage(sinceDaysAgo: 35, now: fixedNow)
        XCTAssertEqual(records.count, 3)
        let r = records[0]
        XCTAssertEqual(r.vendor, "openrouter")
        XCTAssertEqual(r.accountID, "acc1")
        XCTAssertEqual(r.apiKeyID, "claude-code")     // from /key label; account-level rows attributed to it
        XCTAssertEqual(r.day, "2026-07-19")
        XCTAssertEqual(r.costUSD, 1.40, accuracy: 0.001)
        XCTAssertEqual(r.tokensIn, 1000)
        XCTAssertEqual(r.tokensOut, 500)
    }

    func testAuthErrorSurfacesAsAuth() async throws {
        let http = FakeHTTP(); http.responses["/credits"] = (#"{"error":"bad key"}"#, 401)
        do {
            _ = try await makeProvider(http).fetchBalance()
            XCTFail("expected auth error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "auth")
        }
    }

    func testGarbageBodySurfacesAsDecode() async throws {
        let http = FakeHTTP(); http.responses["/credits"] = ("<html>oops</html>", 200)
        do {
            _ = try await makeProvider(http).fetchBalance()
            XCTFail("expected decode error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "decode")
        }
    }

    func testValidateCredentialsReturnsKeyLabel() async throws {
        let http = FakeHTTP(); http.responses["/key"] = (keyJSON, 200)
        let info = try await makeProvider(http).validateCredentials()
        XCTAssertEqual(info.label, "claude-code")
    }

    // MARK: per-key daily totals via /activity?api_key_hash=

    // Hashes chosen so each key's activity URL contains a unique substring.
    let keysWithHashesJSON = #"""
    {"data":[
      {"name":"prod","label":"sk-or-v1-aaa","hash":"hashAAA111","usage":120.5,"disabled":false},
      {"name":null,"label":"ci-key","hash":"hashBBB222","usage":3.0,"disabled":false},
      {"name":"no-hash-key","label":"legacy","usage":9.9,"disabled":false}
    ]}
    """#
    // 1782777600 s = 2026-06-30 (prev month), now = 2026-07-01T12:00Z (1_782_907_200).
    let activityAJSON = #"""
    {"data":[
      {"date":"2026-06-30 00:00:00","model":"openai/gpt-4.1","usage":3.0,"requests":2,"prompt_tokens":10,"completion_tokens":5},
      {"date":"2026-07-01 00:00:00","model":"openai/gpt-4.1","usage":2.0,"requests":1,"prompt_tokens":4,"completion_tokens":2}
    ]}
    """#
    let activityBJSON = #"""
    {"data":[
      {"date":"2026-07-01 00:00:00","model":"anthropic/claude-sonnet-5","usage":5.0,"requests":1,"prompt_tokens":9,"completion_tokens":3}
    ]}
    """#

    func testKeyTotalsPerKeyDailyAcrossMonthBoundary() async throws {
        let http = FakeHTTP()
        http.responses["keys"] = (keysWithHashesJSON, 200)
        http.responses["api_key_hash=hashAAA111"] = (activityAJSON, 200)
        http.responses["api_key_hash=hashBBB222"] = (activityBJSON, 200)
        let provider = makeProvider(http)
        let totals = try await provider.fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
        XCTAssertEqual(totals.count, 2, "key without hash is skipped")
        XCTAssertEqual(totals[0].apiKeyID, "ci-key", "sorted by MTD desc; name nil → label")
        XCTAssertEqual(totals[0].totalUSD, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].todayUSD ?? -1, 5.0, accuracy: 0.001)
        let prod = totals.first { $0.apiKeyID == "prod" }!
        XCTAssertEqual(prod.totalUSD, 5.0, accuracy: 0.001)   // 3 + 2, both inside 30d window
        XCTAssertEqual(prod.mtdUSD ?? -1, 2.0, accuracy: 0.001)   // 06-30 is last month
        XCTAssertEqual(prod.todayUSD ?? -1, 2.0, accuracy: 0.001)
    }

    func testKeyTotalsEmptyWhenNoKeysHaveActivity() async throws {
        let http = FakeHTTP()
        http.responses["keys"] = (keysWithHashesJSON, 200)
        http.responses["api_key_hash="] = (#"{"data":[]}"#, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
        XCTAssertTrue(totals.isEmpty)
    }

    func testKeyActivityErrorPropagates() async throws {
        let http = FakeHTTP()
        http.responses["keys"] = (keysWithHashesJSON, 200)
        http.responses["api_key_hash="] = (#"{"error":"boom"}"#, 500)
        do {
            _ = try await makeProvider(http).fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
            XCTFail("expected transient error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "transient")
        }
    }
}

final class ClassifyHTTPTests: XCTestCase {
    func testSuccessReturnsNil() {
        XCTAssertNil(classifyHTTP(status: 200, data: Data()))
    }

    func testUnauthorizedIsAuth() {
        guard case .auth(401, _)? = classifyHTTP(status: 401, data: Data()) else {
            return XCTFail("expected auth")
        }
    }

    func testForbiddenIsAuth() {
        guard case .auth(403, _)? = classifyHTTP(status: 403, data: Data()) else {
            return XCTFail("expected auth")
        }
    }

    func testTooManyRequestsIsTransient() {
        guard case .transient? = classifyHTTP(status: 429, data: Data()) else {
            return XCTFail("expected transient")
        }
    }

    func testServerErrorIsTransient() {
        guard case .transient? = classifyHTTP(status: 500, data: Data()) else {
            return XCTFail("expected transient")
        }
    }

    func testServiceUnavailableIsTransient() {
        guard case .transient? = classifyHTTP(status: 503, data: Data()) else {
            return XCTFail("expected transient")
        }
    }

    func testTeapotIsHTTP() {
        guard case .http(418, _)? = classifyHTTP(status: 418, data: Data()) else {
            return XCTFail("expected http")
        }
    }

    func testSnippetIsTruncatedTo300Chars() {
        let body = String(repeating: "x", count: 400)
        guard case .http(418, let snippet)? = classifyHTTP(status: 418, data: Data(body.utf8)) else {
            return XCTFail("expected http")
        }
        XCTAssertLessThanOrEqual(snippet.count, 310)
    }
}
