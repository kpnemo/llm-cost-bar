import Foundation

public protocol HTTPClient: Sendable {
    func get(_ url: URL, bearer: String) async throws -> (Data, Int)
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int)
    func post(_ url: URL, json: [String: String]) async throws -> (Data, Int)
}

public extension HTTPClient {
    /// Default for test doubles that only stub the bearer variant.
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        try await get(url, bearer: "")
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL, bearer: String) async throws -> (Data, Int) {
        try await get(url, headers: ["Authorization": "Bearer \(bearer)"])
    }
    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as! HTTPURLResponse).statusCode)
    }
    public func post(_ url: URL, json: [String: String]) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(json)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as! HTTPURLResponse).statusCode)
    }
}
