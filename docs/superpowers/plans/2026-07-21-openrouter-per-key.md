# OpenRouter Per-Key Three-Column Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OpenRouter's key list shows the same real-dollar today/MTD/30d columns as OpenAI, fed by per-key daily activity.

**Architecture:** `OpenRouterProvider.fetchKeyTotals` lists keys (now decoding the `hash` field), fetches `/activity?api_key_hash=<hash>` per key, accumulates per-key-per-day dollars keyed by display name, and returns `KeyTotal.aggregate(...)` — the shared helper Anthropic/OpenAI already use. The UI's `hasWindows` gate flips automatically; only the caption changes.

**Tech Stack:** Swift/SwiftPM, XCTest + FakeHTTP recorded fixtures.

**Spec:** Addendum section in `docs/superpowers/specs/2026-07-20-per-key-columns-design.md`.

---

### Task 1: OpenRouterProvider per-key daily fetch

**Files:**
- Modify: `Core/Sources/LLMCostBarCore/OpenRouterProvider.swift`
- Test: `Core/Tests/LLMCostBarCoreTests/OpenRouterProviderTests.swift`

- [ ] **Step 1: Write failing tests.** Read the test file first to match FakeHTTP conventions (most-specific-substring URL matching). Add:

```swift
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
        let provider = makeProvider(http)   // adapt to the file's existing helper name
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
```
Check the existing `testKeyTotals...` test in this file that asserts lifetime totals from `/keys` — REPLACE it with the above semantics (the old single-number behavior is intentionally removed). Keep other tests (activity/usage, credits, PKCE-adjacent) untouched. If the existing FakeHTTP keys on "keys" would also substring-match the activity URL ("/activity?api_key_hash=..." does not contain "keys" — verify), adjust keys as needed for the most-specific-match rule.

- [ ] **Step 2: Verify failure** — `cd Core && swift test --filter OpenRouterProviderTests`.

- [ ] **Step 3: Implement.** In OpenRouterProvider.swift:
  - `KeysListResp.K` gains `let hash: String?`.
  - Replace `fetchKeyTotals`:

```swift
    /// Real per-key per-day dollars: /keys supplies name + hash, then one
    /// /activity?api_key_hash= call per key returns its daily usage. Keys
    /// without a hash (or with no activity in the window) drop out; display
    /// name falls back name → label → "unnamed". Requires a management key,
    /// same as the pooled /activity call.
    public func fetchKeyTotals(now: Date = Date()) async throws -> [KeyTotal] {
        let keys = try await getJSON("keys", as: KeysListResp.self).data
        var perKeyDay: [String: [String: Double]] = [:]           // display name → day → usd
        for key in keys {
            guard let hash = key.hash else { continue }
            let name = key.name ?? key.label ?? "unnamed"
            let resp = try await getJSON("activity?api_key_hash=\(hash)", as: ActivityResp.self)
            for row in resp.data where row.usage != 0 {
                perKeyDay[name, default: [:]][String(row.date.prefix(10)), default: 0] += row.usage
            }
        }
        guard !perKeyDay.isEmpty else { return [] }
        return KeyTotal.aggregate(perKeyDay: perKeyDay, names: [:], now: now)
    }
```
  Note: `getJSON` builds URLs via `appendingPathComponent`, which percent-encodes "?" — CHECK this. If so, add a variant that appends a query properly (URLComponents with queryItems: [.init(name: "api_key_hash", value: hash)]). The test stubs match on the substring "api_key_hash=" so either construction passes as long as the final URL contains it literally.
  - Update the file-header comment if it mentions lifetime key totals.

- [ ] **Step 4: Full suite** — `cd Core && swift test`. Expect 79-80 tests (77 + new − replaced), 0 failures.

- [ ] **Step 5: Commit** — `git commit -am "feat: OpenRouter per-key daily spend via activity api_key_hash filter"` + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` trailer.

---

### Task 2: Caption + stale comment sync + verification

**Files:**
- Modify: `App/DropdownView.swift` (caption ternary + the comment above it)
- Modify: `Core/Sources/LLMCostBarCore/Models.swift` (KeyTotal doc comment)
- Modify: `Core/Sources/LLMCostBarCore/UsageStore.swift` (KeySpend totalUSD comment)
- Modify: `Core/Sources/LLMCostBarCore/VendorProvider.swift` (protocol comment if it says lifetime)

- [ ] **Step 1:** DropdownView caption becomes:

```swift
                Text(vendor.vendor == "anthropic" ? "API keys · est. spend" : "API keys")
```
and rewrite the comment above it: all three vendors now report per-day per-key dollars (Anthropic estimated, OpenAI/OpenRouter real); the single-column branch remains only as the old-daemon-data fallback.

- [ ] **Step 2:** Update doc comments: KeyTotal ("OpenRouter lifetime" → all vendors 30-day window, OpenRouter real dollars via per-key activity); KeySpend `totalUSD` comment; VendorProvider `fetchKeyTotals` comment.

- [ ] **Step 3:** `cd Core && swift test` (green) and `xcodegen generate && xcodebuild -scheme LLMCostBar build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3` (BUILD SUCCEEDED).

- [ ] **Step 4:** Commit — `git commit -am "feat: OpenRouter key list joins three-column layout"` + trailer.
