import XCTest
@testable import LLMCostBarCore

final class WithRetryTests: XCTestCase {
    /// Counting op: fails with the given error `failures` times, then returns "ok".
    private func makeOp(failures: Int, error: ProviderError,
                        calls: UnsafeMutablePointer<Int>? = nil) -> @Sendable () async throws -> String {
        let counter = Counter()
        return {
            let n = counter.next()
            calls?.pointee = n
            if n <= failures { throw error }
            return "ok"
        }
    }

    /// withRetry is generic over Sendable; a tiny reference box lets us count invocations
    /// across the Sendable closure boundary in tests.
    private final class Counter: @unchecked Sendable {
        private var n = 0
        func next() -> Int { n += 1; return n }
    }

    func testSucceedsFirstTryDoesNotSleep() async throws {
        var slept: [Double] = []
        let value = try await withRetry(sleeper: { slept.append($0) }) { "ok" }
        XCTAssertEqual(value, "ok")
        XCTAssertTrue(slept.isEmpty)
    }

    func testRetriesTransientThenSucceeds() async throws {
        var slept: [Double] = []
        let op = makeOp(failures: 2, error: .transient("flaky"))
        let value = try await withRetry(sleeper: { slept.append($0) }, op)
        XCTAssertEqual(value, "ok")
        XCTAssertEqual(slept, [1.0, 2.0], "exponential backoff: 1s then 2s")
    }

    func testTransientExhaustsAttemptsAndThrows() async throws {
        var slept: [Double] = []
        let op = makeOp(failures: 99, error: .transient("down"))
        do {
            _ = try await withRetry(sleeper: { slept.append($0) }, op)
            XCTFail("expected transient to be rethrown after exhausting attempts")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "transient")
        }
        XCTAssertEqual(slept, [1.0, 2.0], "3 attempts → 2 sleeps")
    }

    func testDoesNotRetryAuth() async throws {
        var slept: [Double] = []
        let op = makeOp(failures: 99, error: .auth(401, "bad key"))
        do {
            _ = try await withRetry(sleeper: { slept.append($0) }, op)
            XCTFail("expected auth error")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        }
        XCTAssertTrue(slept.isEmpty, "auth errors must not be retried (no retry-hammering dead keys)")
    }

    func testDoesNotRetryDecode() async throws {
        var slept: [Double] = []
        let op = makeOp(failures: 99, error: .decode("shape changed"))
        do {
            _ = try await withRetry(sleeper: { slept.append($0) }, op)
            XCTFail("expected decode error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "decode")
        }
        XCTAssertTrue(slept.isEmpty, "decode errors are deterministic — retrying won't help")
    }

    func testDoesNotRetryHTTP() async throws {
        var slept: [Double] = []
        let op = makeOp(failures: 99, error: .http(418, "teapot"))
        do {
            _ = try await withRetry(sleeper: { slept.append($0) }, op)
            XCTFail("expected http error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "http")
        }
        XCTAssertTrue(slept.isEmpty)
    }

    func testUnknownErrorIsWrappedAsTransientAndRetried() async throws {
        struct Weird: Error {}
        var slept: [Double] = []
        let counter = Counter()
        do {
            _ = try await withRetry(sleeper: { slept.append($0) }) { () -> String in
                _ = counter.next(); throw Weird()
            }
            XCTFail("expected wrapped error")
        } catch let e as ProviderError {
            XCTAssertEqual(e.errorClass, "transient", "non-ProviderError must map to transient")
        }
        XCTAssertEqual(slept, [1.0, 2.0])
    }
}
