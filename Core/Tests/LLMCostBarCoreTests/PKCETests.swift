import XCTest
import CryptoKit
@testable import LLMCostBarCore

final class PKCETests: XCTestCase {
    func testChallengeIsBase64URLSHA256OfVerifier() {
        let pkce = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)      // RFC 7636 minimum
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pkce.challenge, expected)
    }

    func testAuthURLContainsCallbackAndChallenge() {
        let pkce = PKCE(verifier: "v", challenge: "c")
        let url = OpenRouterPairing.authURL(pkce: pkce, callbackURL: "http://localhost:18923/callback")
        let s = url.absoluteString
        XCTAssertTrue(s.hasPrefix("https://openrouter.ai/auth?"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "callback_url" })?.value, "http://localhost:18923/callback")
        XCTAssertTrue(s.contains("code_challenge=c"))
        XCTAssertTrue(s.contains("code_challenge_method=S256"))
    }

    func testCallbackCodeExtraction() {
        let url = URL(string: "llmcostbar://callback?code=abc123")!
        XCTAssertEqual(OpenRouterPairing.code(fromCallback: url), "abc123")
        XCTAssertNil(OpenRouterPairing.code(fromCallback: URL(string: "llmcostbar://callback")!))
        XCTAssertNil(OpenRouterPairing.code(fromCallback: URL(string: "https://callback?code=abc123")!))
        XCTAssertNil(OpenRouterPairing.code(fromCallback: URL(string: "llmcostbar://other?code=abc123")!))
    }

    func testExchangeParsesKey() async throws {
        let http = FakeHTTP()
        http.responses["/auth/keys"] = (#"{"key":"sk-or-v1-newkey"}"#, 200)
        let key = try await OpenRouterPairing.exchange(code: "abc", verifier: "v", http: http)
        XCTAssertEqual(key, "sk-or-v1-newkey")
    }
}
