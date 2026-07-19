import Foundation
import CryptoKit

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public init(verifier: String, challenge: String) { self.verifier = verifier; self.challenge = challenge }

    public static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 48)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        let verifier = Data(bytes).base64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        return PKCE(verifier: verifier, challenge: challenge)
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum OpenRouterPairing {
    public static let callbackScheme = "llmcostbar"

    /// OpenRouter rejects custom URL scheme callback_urls client-side (it redirects to
    /// the homepage instead of showing the consent page), so callers must pass a real
    /// http(s) loopback URL (see LoopbackServer). The llmcostbar:// scheme is kept only
    /// for `code(fromCallback:)`'s legacy handling.
    public static func authURL(pkce: PKCE, callbackURL: String) -> URL {
        var c = URLComponents(string: "https://openrouter.ai/auth")!
        c.queryItems = [
            .init(name: "callback_url", value: callbackURL),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return c.url!
    }

    public static func code(fromCallback url: URL) -> String? {
        guard url.scheme == callbackScheme, url.host == "callback" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
    }

    public static func exchange(code: String, verifier: String,
                                http: HTTPClient = URLSessionHTTPClient()) async throws -> String {
        struct Resp: Decodable { let key: String }
        let url = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
        let (data, status) = try await http.post(url, json: [
            "code": code, "code_verifier": verifier, "code_challenge_method": "S256",
        ])
        if let err = classifyHTTP(status: status, data: data) { throw err }
        guard let resp = try? JSONDecoder().decode(Resp.self, from: data) else {
            throw ProviderError.decode("auth/keys response: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
        }
        return resp.key
    }
}
