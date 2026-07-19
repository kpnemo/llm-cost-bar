import XCTest
@testable import LLMCostBarCore

final class FakeHTTP: HTTPClient, @unchecked Sendable {
    var responses: [String: (String, Int)] = [:]   // url substring → (body, status)
    func get(_ url: URL, bearer: String) async throws -> (Data, Int) {
        for (k, v) in responses where url.absoluteString.contains(k) {
            return (Data(v.0.utf8), v.1)
        }
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
      {"date":"2026-07-19","model":"anthropic/claude-sonnet-4","usage":1.40,"requests":10,"prompt_tokens":1000,"completion_tokens":500},
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
