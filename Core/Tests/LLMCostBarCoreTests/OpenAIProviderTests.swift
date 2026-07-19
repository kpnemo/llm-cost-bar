import XCTest
@testable import LLMCostBarCore

final class OpenAIProviderTests: XCTestCase {
    // Per docs: unix-second buckets; amount.value in dollars; line_item carries
    // the model plus a ", input"/", output" suffix. 1784332800 = 2026-07-18T00:00:00Z.
    let lineItemCostsJSON = #"""
    {"data":[
      {"object":"bucket","start_time":1784332800,"end_time":1784419200,"results":[
        {"object":"organization.costs.result","amount":{"value":12.34,"currency":"usd"},"line_item":"GPT-4o, input","project_id":"proj_1"},
        {"object":"organization.costs.result","amount":{"value":2.66,"currency":"usd"},"line_item":"GPT-4o, output","project_id":"proj_1"},
        {"object":"organization.costs.result","amount":{"value":0.5,"currency":"usd"},"line_item":"Code interpreter sessions","project_id":"proj_1"},
        {"object":"organization.costs.result","amount":{"value":0,"currency":"usd"},"line_item":"o1, input","project_id":"proj_1"}
      ]}
    ],"has_more":false,"next_page":null}
    """#
    let keyCostsJSON = #"""
    {"data":[
      {"object":"bucket","start_time":1784332800,"end_time":1784419200,"results":[
        {"object":"organization.costs.result","amount":{"value":10.0,"currency":"usd"},"api_key_id":"key_A"},
        {"object":"organization.costs.result","amount":{"value":5.0,"currency":"usd"},"api_key_id":"key_B"},
        {"object":"organization.costs.result","amount":{"value":1.0,"currency":"usd"},"api_key_id":null}
      ]}
    ],"has_more":false,"next_page":null}
    """#
    let projectsJSON = #"{"data":[{"id":"proj_1","name":"Default project"}],"has_more":false,"last_id":"proj_1"}"#
    let projectKeysJSON = #"{"data":[{"id":"key_A","name":"prod"},{"id":"key_B","name":null}],"has_more":false,"last_id":"key_B"}"#

    func makeProvider(_ http: FakeHTTP) -> OpenAIProvider {
        OpenAIProvider(accountID: "acc-o", credential: Credential(apiKey: "sk-admin-test"), http: http)
    }

    func testFetchUsageMergesLineItemsPerModelPerDay() async throws {
        let http = FakeHTTP(); http.responses["group_by=line_item"] = (lineItemCostsJSON, 200)
        let records = try await makeProvider(http).fetchUsage(sinceDaysAgo: 30, now: Date())
        // GPT-4o input+output merged; sessions kept; zero o1 row kept (so vendor
        // corrections can overwrite stale data via the upsert)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first { $0.model == "o1" }?.costUSD, 0)
        let gpt4o = records.first { $0.model == "GPT-4o" }
        XCTAssertEqual(gpt4o?.costUSD ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(gpt4o?.day, "2026-07-18")   // from unix start_time
        XCTAssertEqual(gpt4o?.vendor, "openai")
        XCTAssertEqual(gpt4o?.apiKeyID, "org")
        let sessions = records.first { $0.model == "Code interpreter sessions" }
        XCTAssertEqual(sessions?.costUSD ?? 0, 0.5, accuracy: 0.001)
    }

    // Fixture bucket day is 2026-07-18 (see keyCostsJSON's start_time comment
    // below); fix `now` to a later day in the same UTC month so mtd/today are
    // deterministic instead of drifting with the real clock.
    // 1784980800 = 2026-07-25T12:00:00Z.
    let fixedNow = Date(timeIntervalSince1970: 1_784_980_800)

    func testKeyTotalsAreRealDollarsWithNames() async throws {
        let http = FakeHTTP()
        http.responses["group_by=api_key_id"] = (keyCostsJSON, 200)
        http.responses["organization/projects?"] = (projectsJSON, 200)
        http.responses["proj_1/api_keys"] = (projectKeysJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: fixedNow)
        XCTAssertEqual(totals.count, 2)                    // keyless row skipped
        XCTAssertEqual(totals[0].apiKeyID, "prod")         // named via project keys list
        XCTAssertEqual(totals[0].totalUSD, 10.0, accuracy: 0.001)
        // Whole window falls in the fixed now's month → mtd == total; fixture
        // day (07-18) isn't fixedNow's day (07-25) → today is 0.
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 10.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].todayUSD ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(totals[1].apiKeyID, "key_B")        // no name → raw id
        XCTAssertEqual(totals[1].totalUSD, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[1].mtdUSD ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[1].todayUSD ?? -1, 0.0, accuracy: 0.001)
    }

    func testKeyNamesFailureFallsBackToIDs() async throws {
        let http = FakeHTTP()
        http.responses["group_by=api_key_id"] = (keyCostsJSON, 200)
        http.responses["organization/projects?"] = (#"{"error":"forbidden"}"#, 403)
        let totals = try await makeProvider(http).fetchKeyTotals(now: fixedNow)
        XCTAssertEqual(totals.map(\.apiKeyID).sorted(), ["key_A", "key_B"])
    }

    // Live API has returned numeric strings where docs show numbers.
    func testFetchUsageToleratesStringNumbers() async throws {
        let stringyJSON = #"""
        {"data":[
          {"object":"bucket","start_time":"1784332800","end_time":"1784419200","results":[
            {"object":"organization.costs.result","amount":{"value":"12.5","currency":"usd"},"line_item":"GPT-4o, input","project_id":"proj_1"}
          ]}
        ],"has_more":false,"next_page":null}
        """#
        let http = FakeHTTP(); http.responses["group_by=line_item"] = (stringyJSON, 200)
        let records = try await makeProvider(http).fetchUsage(sinceDaysAgo: 30, now: Date())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].costUSD, 12.5, accuracy: 0.001)
        XCTAssertEqual(records[0].day, "2026-07-18")
    }

    func testAdminKeyRejectionSurfacesAsAuth() async throws {
        let http = FakeHTTP()
        http.responses["group_by=line_item"] = (#"{"error":{"message":"insufficient permissions","type":"invalid_request_error"}}"#, 401)
        do {
            _ = try await makeProvider(http).fetchUsage(sinceDaysAgo: 2, now: Date())
            XCTFail("expected auth error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "auth")
        }
    }

    /// The costs API paginates via has_more/next_page (page=<token> query param).
    /// Key totals must accumulate across pages, not just the first.
    func testKeyTotalsAccumulateAcrossPages() async throws {
        let http = FakeHTTP()
        // Page 1 (URL has the group_by param but no page token).
        http.responses["group_by=api_key_id"] = (#"""
        {"data":[{"object":"bucket","start_time":1784332800,"end_time":1784419200,"results":[
          {"object":"organization.costs.result","amount":{"value":10.0,"currency":"usd"},"api_key_id":"key_A"}
        ]}],"has_more":true,"next_page":"tok2"}
        """#, 200)
        // Page 2 (URL now also contains "page=tok2"). The stub key includes the
        // trailing page token so it's longer than the page-1 "group_by=api_key_id"
        // key and wins FakeHTTP's most-specific-match.
        http.responses["group_by=api_key_id&limit=31&page=tok2"] = (#"""
        {"data":[{"object":"bucket","start_time":1784332800,"end_time":1784419200,"results":[
          {"object":"organization.costs.result","amount":{"value":5.0,"currency":"usd"},"api_key_id":"key_B"},
          {"object":"organization.costs.result","amount":{"value":2.0,"currency":"usd"},"api_key_id":"key_A"}
        ]}],"has_more":false,"next_page":null}
        """#, 200)
        http.responses["organization/projects?"] = (projectsJSON, 200)
        http.responses["proj_1/api_keys"] = (projectKeysJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: fixedNow)
        XCTAssertEqual(totals.first { $0.apiKeyID == "prod" }?.totalUSD ?? 0, 12.0, accuracy: 0.001,
                       "key_A must sum 10 (page 1) + 2 (page 2)")
        XCTAssertEqual(totals.first { $0.apiKeyID == "key_B" }?.totalUSD ?? 0, 5.0, accuracy: 0.001)
    }

    // 1782777600 = 2026-06-30T00:00Z, 1782864000 = 2026-07-01T00:00Z.
    // now = 2026-07-01T12:00Z → key_B is all-MTD/all-today; key_A splits.
    func testKeyTotalsSplitTodayMTDAcrossMonthBoundary() async throws {
        let json = #"""
        {"data":[
          {"start_time":1782777600,"results":[
            {"amount":{"value":3.0,"currency":"usd"},"api_key_id":"key_A"}
          ]},
          {"start_time":1782864000,"results":[
            {"amount":{"value":2.0,"currency":"usd"},"api_key_id":"key_A"},
            {"amount":{"value":5.0,"currency":"usd"},"api_key_id":"key_B"}
          ]}
        ],"has_more":false,"next_page":null}
        """#
        let http = FakeHTTP()
        http.responses["organization/costs"] = (json, 200)
        // name lookup fail-soft → raw ids
        http.responses["organization/projects?"] = (#"{"error":"nope"}"#, 500)
        let totals = try await makeProvider(http).fetchKeyTotals(now: Date(timeIntervalSince1970: 1_782_907_200))
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].apiKeyID, "key_B", "sorted by MTD desc")
        XCTAssertEqual(totals[0].totalUSD, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 5.0, accuracy: 0.001)
        XCTAssertEqual(totals[0].todayUSD ?? -1, 5.0, accuracy: 0.001)
        let a = totals.first { $0.apiKeyID == "key_A" }!
        XCTAssertEqual(a.totalUSD, 5.0, accuracy: 0.001)
        XCTAssertEqual(a.mtdUSD ?? -1, 2.0, accuracy: 0.001)
        XCTAssertEqual(a.todayUSD ?? -1, 2.0, accuracy: 0.001)
    }
}
