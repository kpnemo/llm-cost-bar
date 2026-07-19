import XCTest
@testable import LLMCostBarCore

final class AnthropicProviderTests: XCTestCase {
    // Per docs: buckets with results; amount = decimal string in cents; grouping by
    // description adds parsed fields like model.
    let costJSON = #"""
    {"data":[
      {"starting_at":"2026-07-18T00:00:00Z","ending_at":"2026-07-19T00:00:00Z","results":[
        {"currency":"USD","amount":"1234","model":"claude-opus-4-8","description":"Claude Opus 4.8 input tokens"},
        {"currency":"USD","amount":"250","model":"claude-opus-4-8","description":"Claude Opus 4.8 output tokens"},
        {"currency":"USD","amount":"77","model":"claude-haiku-4-5","description":"Claude Haiku 4.5 input tokens"}
      ]},
      {"starting_at":"2026-07-19T00:00:00Z","ending_at":"2026-07-20T00:00:00Z","results":[
        {"currency":"USD","amount":"500","model":"claude-opus-4-8","description":"x"},
        {"currency":"USD","amount":"0","model":"claude-haiku-4-5","description":"zero row dropped"}
      ]}
    ],"has_more":false,"next_page":null}
    """#

    func makeProvider(_ http: FakeHTTP) -> AnthropicProvider {
        AnthropicProvider(accountID: "acc-a", credential: Credential(apiKey: "sk-ant-admin01-test"), http: http)
    }

    func testCostReportNormalizesAndMergesPerModelPerDay() async throws {
        let http = FakeHTTP(); http.responses["cost_report"] = (costJSON, 200)
        let records = try await makeProvider(http).fetchUsage(sinceDaysAgo: 30, now: Date())
        XCTAssertEqual(records.count, 3)   // opus/18th merged, haiku/18th, opus/19th; zero row dropped
        let opus18 = records.first { $0.model == "claude-opus-4-8" && $0.day == "2026-07-18" }
        XCTAssertEqual(opus18?.costUSD ?? 0, 14.84, accuracy: 0.001)   // (1234+250) cents
        XCTAssertEqual(opus18?.vendor, "anthropic")
        XCTAssertEqual(opus18?.apiKeyID, "org")
        let haiku18 = records.first { $0.model == "claude-haiku-4-5" && $0.day == "2026-07-18" }
        XCTAssertEqual(haiku18?.costUSD ?? 0, 0.77, accuracy: 0.001)
    }

    func testAdminKeyRejectionSurfacesAsAuth() async throws {
        let http = FakeHTTP()
        http.responses["cost_report"] = (#"{"type":"error","error":{"type":"permission_error","message":"admin key required"}}"#, 403)
        do {
            _ = try await makeProvider(http).fetchUsage(sinceDaysAgo: 2, now: Date())
            XCTFail("expected auth error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "auth")
        }
    }

    func testBalanceIsNilAndKeyTotalsEmpty() async throws {
        let http = FakeHTTP()
        let p = makeProvider(http)
        let balance = try await p.fetchBalance()
        XCTAssertNil(balance)
        let totals = try await p.fetchKeyTotals()
        XCTAssertTrue(totals.isEmpty)
    }
}
