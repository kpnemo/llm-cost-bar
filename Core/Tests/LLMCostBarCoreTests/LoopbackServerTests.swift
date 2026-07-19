import XCTest
@testable import LLMCostBarCore

final class LoopbackServerTests: XCTestCase {
    func testReceivesCodeAndResponds() throws {
        let server = LoopbackServer()
        let codeExp = expectation(description: "code delivered")
        var receivedCode: String?
        try server.start { code in
            receivedCode = code
            codeExp.fulfill()
        }

        let url = URL(string: "http://localhost:\(server.port)/callback?code=test-code-123")!
        let httpExp = expectation(description: "http response")
        var statusCode = 0
        var bodyText = ""
        URLSession.shared.dataTask(with: url) { data, response, _ in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            bodyText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            httpExp.fulfill()
        }.resume()

        wait(for: [httpExp, codeExp], timeout: 5)
        XCTAssertEqual(statusCode, 200)
        XCTAssertTrue(bodyText.contains("LLM Cost Bar"))
        XCTAssertEqual(receivedCode, "test-code-123")
    }

    func testNonCallbackPathReturns400() throws {
        let server = LoopbackServer()
        var deliveredCode: String?
        try server.start { code in deliveredCode = code }

        let badExp = expectation(description: "bad path response")
        var badStatus = 0
        let badURL = URL(string: "http://localhost:\(server.port)/favicon.ico")!
        URLSession.shared.dataTask(with: badURL) { _, response, _ in
            badStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            badExp.fulfill()
        }.resume()
        wait(for: [badExp], timeout: 5)
        XCTAssertEqual(badStatus, 400)
        XCTAssertNil(deliveredCode, "onCode must not fire for a non-matching request")

        // Server must keep listening after a 400.
        let goodExp = expectation(description: "good path response")
        var goodStatus = 0
        let goodURL = URL(string: "http://localhost:\(server.port)/callback?code=abc")!
        URLSession.shared.dataTask(with: goodURL) { _, response, _ in
            goodStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            goodExp.fulfill()
        }.resume()
        wait(for: [goodExp], timeout: 5)
        XCTAssertEqual(goodStatus, 200)
        XCTAssertEqual(deliveredCode, "abc")
    }
}
