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
        // opus/18th merged, haiku/18th, opus/19th, haiku/19th (zero rows kept so
        // vendor corrections can overwrite stale data via the upsert)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(records.first { $0.model == "claude-haiku-4-5" && $0.day == "2026-07-19" }?.costUSD, 0)
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

    func testBalanceIsNil() async throws {
        let balance = try await makeProvider(FakeHTTP()).fetchBalance()
        XCTAssertNil(balance)
    }

    // Per-key estimation fixtures: usage_report gives weighted tokens per
    // (key, model); cost_report gives dollars per model. Weights below:
    //   key A on opus (dated model id): 875 uncached + 1.25*100 cache-5m + 5*100 output = 1500
    //   key B on opus:                  250 uncached + 0.1*2500 cache-read           =  500
    //   key B on haiku:                 2000 uncached                                 = 2000
    let usageJSON = #"""
    {"data":[
      {"starting_at":"2026-07-18T00:00:00Z","ending_at":"2026-07-19T00:00:00Z","results":[
        {"api_key_id":"apikey_A","model":"claude-opus-4-8-20260101","uncached_input_tokens":875,
         "cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0},
         "cache_read_input_tokens":0,"output_tokens":100},
        {"api_key_id":"apikey_B","model":"claude-opus-4-8","uncached_input_tokens":250,
         "cache_read_input_tokens":2500,"output_tokens":0},
        {"api_key_id":"apikey_B","model":"claude-haiku-4-5","uncached_input_tokens":2000}
      ]}
    ],"has_more":false,"next_page":null}
    """#
    // opus $20 split 1500:500 → A 15, B 5. haiku $1 → B. claude-unknown-9 $4 has
    // no usage rows → split by overall weight 1500:2500 → A 1.5, B 2.5.
    let keyCostJSON = #"""
    {"data":[
      {"starting_at":"2026-07-18T00:00:00Z","ending_at":"2026-07-19T00:00:00Z","results":[
        {"currency":"USD","amount":"2000","model":"claude-opus-4-8","description":"opus"},
        {"currency":"USD","amount":"100","model":"claude-haiku-4-5","description":"haiku"},
        {"currency":"USD","amount":"400","model":"claude-unknown-9","description":"mystery"}
      ]}
    ],"has_more":false,"next_page":null}
    """#
    let keysListJSON = #"""
    {"data":[{"id":"apikey_A","name":"prod"},{"id":"apikey_B","name":null}],
     "has_more":false,"last_id":"apikey_B"}
    """#

    /// Fixed clock in the same month as the 2026-07-18 fixtures above:
    /// 2026-07-20T12:00:00Z. Removes wall-clock dependence from MTD math.
    let julyTwentiethNoon = Date(timeIntervalSince1970: 1_784_548_800)

    func testKeyTotalsAllocateCostByWeightedTokens() async throws {
        let http = FakeHTTP()
        http.responses["usage_report"] = (usageJSON, 200)
        http.responses["cost_report"] = (keyCostJSON, 200)
        http.responses["api_keys"] = (keysListJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyTwentiethNoon)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].apiKeyID, "prod")            // named via api_keys list
        XCTAssertEqual(totals[0].totalUSD, 16.5, accuracy: 0.01)
        XCTAssertEqual(totals[1].apiKeyID, "apikey_B")        // no name → raw id
        XCTAssertEqual(totals[1].totalUSD, 8.5, accuracy: 0.01)
        // Estimates must sum to the vendor-reported total ($25).
        XCTAssertEqual(totals.map(\.totalUSD).reduce(0, +), 25.0, accuracy: 0.01)
        XCTAssertEqual(totals[0].mtdUSD ?? -1, 16.5, accuracy: 0.01)  // whole window in-month
        XCTAssertEqual(totals[0].todayUSD ?? -1, 0.0, accuracy: 0.01) // fixtures are 07-18, now is 07-20
    }

    func testKeyTotalsEmptyWhenNoUsage() async throws {
        let http = FakeHTTP()
        http.responses["usage_report"] = (#"{"data":[],"has_more":false,"next_page":null}"#, 200)
        http.responses["cost_report"] = (#"{"data":[],"has_more":false,"next_page":null}"#, 200)
        http.responses["api_keys"] = (#"{"data":[],"has_more":false,"last_id":null}"#, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyTwentiethNoon)
        XCTAssertTrue(totals.isEmpty)
    }

    func testKeyNamesFailureFallsBackToIDs() async throws {
        let http = FakeHTTP()
        http.responses["usage_report"] = (usageJSON, 200)
        http.responses["cost_report"] = (keyCostJSON, 200)
        http.responses["api_keys"] = (#"{"error":"forbidden"}"#, 403)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyTwentiethNoon)
        XCTAssertEqual(totals.map(\.apiKeyID).sorted(), ["apikey_A", "apikey_B"])
    }

    /// Fixed clock: 2026-07-01T12:00:00Z — makes MTD/today assertions month-boundary-proof.
    let julyFirstNoon = Date(timeIntervalSince1970: 1_782_907_200)

    // Month boundary: usage/cost on 06-30 (key A) and 07-01 (key B), now = 07-01.
    // Day-scoped allocation: 06-30's $10 must go to A only (B has zero weight that
    // day despite a bigger window weight), 07-01's $20 to B only.
    let boundaryUsageJSON = #"""
    {"data":[
      {"starting_at":"2026-06-30T00:00:00Z","ending_at":"2026-07-01T00:00:00Z","results":[
        {"api_key_id":"apikey_A","model":"claude-opus-4-8","uncached_input_tokens":1000}
      ]},
      {"starting_at":"2026-07-01T00:00:00Z","ending_at":"2026-07-02T00:00:00Z","results":[
        {"api_key_id":"apikey_B","model":"claude-opus-4-8","uncached_input_tokens":2000}
      ]}
    ],"has_more":false,"next_page":null}
    """#
    let boundaryCostJSON = #"""
    {"data":[
      {"starting_at":"2026-06-30T00:00:00Z","ending_at":"2026-07-01T00:00:00Z","results":[
        {"currency":"USD","amount":"1000","model":"claude-opus-4-8","description":"opus"}
      ]},
      {"starting_at":"2026-07-01T00:00:00Z","ending_at":"2026-07-02T00:00:00Z","results":[
        {"currency":"USD","amount":"2000","model":"claude-opus-4-8","description":"opus"}
      ]}
    ],"has_more":false,"next_page":null}
    """#

    func testKeyTotalsSplitTodayMTDAcrossMonthBoundary() async throws {
        let http = FakeHTTP()
        http.responses["usage_report"] = (boundaryUsageJSON, 200)
        http.responses["cost_report"] = (boundaryCostJSON, 200)
        http.responses["api_keys"] = (keysListJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyFirstNoon)
        XCTAssertEqual(totals.count, 2)
        let a = totals.first { $0.apiKeyID == "prod" }!        // apikey_A, named
        XCTAssertEqual(a.totalUSD, 10.0, accuracy: 0.01)
        XCTAssertEqual(a.mtdUSD ?? -1, 0.0, accuracy: 0.01)    // 06-30 is last month
        XCTAssertEqual(a.todayUSD ?? -1, 0.0, accuracy: 0.01)
        let b = totals.first { $0.apiKeyID == "apikey_B" }!
        XCTAssertEqual(b.totalUSD, 20.0, accuracy: 0.01)
        XCTAssertEqual(b.mtdUSD ?? -1, 20.0, accuracy: 0.01)   // MTD == today on the 1st
        XCTAssertEqual(b.todayUSD ?? -1, 20.0, accuracy: 0.01)
        XCTAssertEqual(totals[0].apiKeyID, "apikey_B", "sorted by MTD desc")
    }

    // A day with cost but no usage rows at all falls back to window-wide weights.
    func testZeroWeightDayFallsBackToWindowWeights() async throws {
        let usageOnly0630 = #"""
        {"data":[
          {"starting_at":"2026-06-30T00:00:00Z","ending_at":"2026-07-01T00:00:00Z","results":[
            {"api_key_id":"apikey_A","model":"claude-opus-4-8","uncached_input_tokens":1000}
          ]}
        ],"has_more":false,"next_page":null}
        """#
        let http = FakeHTTP()
        http.responses["usage_report"] = (usageOnly0630, 200)
        http.responses["cost_report"] = (boundaryCostJSON, 200)   // cost on both days
        http.responses["api_keys"] = (keysListJSON, 200)
        let totals = try await makeProvider(http).fetchKeyTotals(now: julyFirstNoon)
        let a = totals.first { $0.apiKeyID == "prod" }!
        XCTAssertEqual(a.totalUSD, 30.0, accuracy: 0.01)   // both days land on A
        XCTAssertEqual(a.mtdUSD ?? -1, 20.0, accuracy: 0.01)
        XCTAssertEqual(a.todayUSD ?? -1, 20.0, accuracy: 0.01)
    }

    /// cost_report paginates via has_more/next_page; all pages must be merged.
    func testFetchUsageMergesAcrossPages() async throws {
        let costJSONPage1 = #"""
        {"data":[{"starting_at":"2026-07-18T00:00:00Z","ending_at":"2026-07-19T00:00:00Z","results":[
          {"currency":"USD","amount":"1000","model":"claude-opus-4-8","description":"opus p1"}
        ]}],"has_more":true,"next_page":"page-2"}
        """#
        let costJSONPage2 = #"""
        {"data":[{"starting_at":"2026-07-18T00:00:00Z","ending_at":"2026-07-19T00:00:00Z","results":[
          {"currency":"USD","amount":"500","model":"claude-opus-4-8","description":"opus p2"}
        ]}],"has_more":false,"next_page":null}
        """#
        let http = FakeHTTP()
        // Page-1 URL is cost_report?<base params> (no page token); page-2 appends
        // &page=page-2. Give page-2 the LONGER key (includes the page token) so it
        // deterministically wins FakeHTTP's most-specific-substring match on page-2's
        // URL, which also contains the short page-1 key.
        http.responses["cost_report"] = (costJSONPage1, 200)          // 11 chars
        http.responses["&page=page-2"] = (costJSONPage2, 200)         // 12 chars, present only in page-2's URL → wins
        let records = try await makeProvider(http).fetchUsage(sinceDaysAgo: 30, now: Date())
        XCTAssertEqual(records.count, 1, "same model+day across pages must merge into one row")
        XCTAssertEqual(records[0].costUSD, 15.0, accuracy: 0.001, "1000+500 cents across two pages")
    }
}
