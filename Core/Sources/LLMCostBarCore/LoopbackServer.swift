import Foundation
import Network

/// Minimal one-shot HTTP callback listener for OAuth-style loopback redirects
/// (`http://localhost:<port>/callback?code=...`). OpenRouter (like most OAuth
/// providers) rejects custom URL scheme callback_urls client-side, so pairing
/// must redirect to a real http(s) loopback address instead of `llmcostbar://`.
///
/// All mutable state is only ever touched from `queue`, which serializes
/// listener/connection callbacks with the calls made from `start`/`stop`
/// (the latter synchronize via the startup semaphore or simply enqueue work).
public final class LoopbackServer: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    public var callbackURL: String { "http://localhost:\(port)/callback" }

    private let queue = DispatchQueue(label: "com.mikeb.llmcostbar.loopback")
    private var listener: NWListener?
    private var onCode: (@Sendable (String) -> Void)?
    private var delivered = false

    public init() {}

    /// Starts listening on 127.0.0.1 at an ephemeral port. Blocks (briefly) until the
    /// listener is ready or 2s elapse, so callers can read `port` immediately after this
    /// returns. `onCode` fires at most once, on an arbitrary queue — hop to the desired
    /// executor (e.g. MainActor) inside the closure.
    public func start(onCode: @escaping @Sendable (String) -> Void) throws {
        self.onCode = onCode

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let sem = DispatchSemaphore(value: 0)
        var startError: Error?
        var signaled = false
        let signalOnce: (Error?) -> Void = { error in
            // stateUpdateHandler can fire more than once (e.g. .setup then .ready);
            // only the first transition to ready/failed should release the wait.
            if signaled { return }
            signaled = true
            startError = error
            sem.signal()
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                signalOnce(nil)
            case .failed(let error):
                signalOnce(error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        if sem.wait(timeout: .now() + 2) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw ProviderError.transient("loopback server did not start within 2s")
        }
        if let startError {
            self.listener = nil
            throw ProviderError.transient("loopback server failed to start: \(startError)")
        }
    }

    public func stop() {
        // Defer both the read and the nil-out onto `queue` — `listener` is otherwise
        // only ever touched from queue-scheduled callbacks, and doing the same here
        // avoids a cross-thread race with e.g. `respond(to:on:)` clearing it concurrently.
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    // MARK: - Connection handling (all on `queue`)

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let requestLine = self.requestLine(in: buffer) {
                self.respond(to: requestLine, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Returns the decoded first line of an HTTP request once a full CRLF-terminated
    /// line has arrived (headers/body, if any, aren't needed for a bare GET).
    private func requestLine(in buffer: Data) -> String? {
        let crlf: [UInt8] = [0x0D, 0x0A]
        guard let range = buffer.firstRange(of: crlf) else { return nil }
        return String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8)
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: "http://localhost" + parts[1]),
              comps.path == "/callback",
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
            send(status: 400, statusText: "Bad Request", body: "Bad Request", on: connection)
            return   // keep listening — do not stop, do not deliver
        }

        let body = """
        <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding-top: 96px;">
        <h2>&#10003; LLM Cost Bar connected</h2>
        <p>you can close this tab and return to the app.</p>
        </body></html>
        """
        send(status: 200, statusText: "OK", body: body, on: connection) { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.deliver(code)
        }
    }

    private func send(status: Int, statusText: String, body: String, on connection: NWConnection,
                       then completion: (() -> Void)? = nil) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(statusText)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var responseData = Data(head.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
            completion?()
        })
    }

    private func deliver(_ code: String) {
        guard !delivered else { return }
        delivered = true
        onCode?(code)
    }
}
