import Foundation

public protocol HTTPClient: Sendable {
    func get(_ url: URL, bearer: String) async throws -> (Data, Int)
    func post(_ url: URL, json: [String: String]) async throws -> (Data, Int)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}
    public func get(_ url: URL, bearer: String) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
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
