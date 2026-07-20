import XCTest
@testable import LLMCostBarCore

final class UpdateServiceTests: XCTestCase {
    /// Trimmed but shape-faithful GitHub `releases/latest` response.
    let latestReleaseJSON = #"""
    {
      "url": "https://api.github.com/repos/kpnemo/llm-cost-bar/releases/236640731",
      "html_url": "https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.3.0",
      "id": 236640731,
      "tag_name": "v1.3.0",
      "target_commitish": "main",
      "name": "LLM Cost Bar 1.3.0",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "url": "https://api.github.com/repos/kpnemo/llm-cost-bar/releases/assets/1",
          "name": "checksums.txt",
          "content_type": "text/plain",
          "size": 120,
          "browser_download_url": "https://github.com/kpnemo/llm-cost-bar/releases/download/v1.3.0/checksums.txt"
        },
        {
          "url": "https://api.github.com/repos/kpnemo/llm-cost-bar/releases/assets/2",
          "name": "LLMCostBar.dmg",
          "content_type": "application/x-apple-diskimage",
          "size": 4194304,
          "browser_download_url": "https://github.com/kpnemo/llm-cost-bar/releases/download/v1.3.0/LLMCostBar.dmg"
        }
      ],
      "body": "release notes here"
    }
    """#

    // MARK: parsing

    func testParsePicksDmgAssetAndStripsTagPrefix() throws {
        let info = try UpdateService.parse(Data(latestReleaseJSON.utf8))
        XCTAssertEqual(info.version, "1.3.0")
        XCTAssertEqual(info.dmgURL.absoluteString,
                       "https://github.com/kpnemo/llm-cost-bar/releases/download/v1.3.0/LLMCostBar.dmg")
        XCTAssertEqual(info.releasePageURL?.absoluteString,
                       "https://github.com/kpnemo/llm-cost-bar/releases/tag/v1.3.0")
    }

    func testParseWithoutDmgAssetThrowsDecode() {
        let json = #"{"tag_name":"v1.3.0","html_url":"https://x","assets":[{"name":"other.zip","browser_download_url":"https://x/other.zip"}]}"#
        XCTAssertThrowsError(try UpdateService.parse(Data(json.utf8))) { error in
            guard case ProviderError.decode = error else {
                return XCTFail("expected .decode, got \(error)")
            }
        }
    }

    func testParseMalformedJSONThrowsDecodeNotCrash() {
        XCTAssertThrowsError(try UpdateService.parse(Data("<html>rate limited</html>".utf8))) { error in
            guard case ProviderError.decode = error else {
                return XCTFail("expected .decode, got \(error)")
            }
        }
    }

    // MARK: semver compare

    func testIsNewerBasics() {
        XCTAssertTrue(UpdateService.isNewer("1.3.0", than: "1.2.0"))
        XCTAssertFalse(UpdateService.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(UpdateService.isNewer("1.1.9", than: "1.2.0"))
    }

    func testIsNewerComparesNumericallyNotLexically() {
        XCTAssertTrue(UpdateService.isNewer("1.10.0", than: "1.2.0"))
        XCTAssertFalse(UpdateService.isNewer("1.2.0", than: "1.10.0"))
    }

    func testIsNewerHandlesDifferentComponentCountsAndVPrefix() {
        XCTAssertTrue(UpdateService.isNewer("1.2.1", than: "1.2"))
        XCTAssertFalse(UpdateService.isNewer("1.2", than: "1.2.0"))
        XCTAssertTrue(UpdateService.isNewer("v2.0", than: "1.9.9"))
    }

    // MARK: check (network via injected fake)

    func testCheckReturnsInfoWhenRemoteIsNewer() async throws {
        let http = FakeHTTP()
        http.responses["releases/latest"] = (latestReleaseJSON, 200)
        let svc = UpdateService(http: http)
        let info = try await svc.checkForUpdate(currentVersion: "1.2.0")
        XCTAssertEqual(info?.version, "1.3.0")
        // GitHub rejects requests without a User-Agent.
        XCTAssertNotNil(http.recordedHeaders["User-Agent"])
    }

    func testCheckReturnsNilWhenUpToDate() async throws {
        let http = FakeHTTP()
        http.responses["releases/latest"] = (latestReleaseJSON, 200)
        let svc = UpdateService(http: http)
        let info = try await svc.checkForUpdate(currentVersion: "1.3.0")
        XCTAssertNil(info)
    }

    func testCheckSurfacesRateLimitAsTransient() async {
        let http = FakeHTTP()
        http.responses["releases/latest"] = (#"{"message":"API rate limit exceeded"}"#, 429)
        let svc = UpdateService(http: http)
        do {
            _ = try await svc.checkForUpdate(currentVersion: "1.2.0")
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .transient = e else { return XCTFail("expected .transient, got \(e)") }
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }
}
