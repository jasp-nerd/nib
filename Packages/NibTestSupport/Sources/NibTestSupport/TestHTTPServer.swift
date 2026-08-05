import Foundation
import Network

/// A minimal HTTP/1.1 server for tests.
///
/// Exists so the engine can be verified against something real rather than a mock. A mock of
/// URLSession would test our assumptions about URLSession, which is precisely the thing we do not
/// trust — the whole point of the fidelity work is finding out what Foundation *actually* puts on
/// the wire.
///
/// Deliberately not a general-purpose server: HTTP/1.1, one request per connection,
/// `Connection: close`, no chunked request bodies, no TLS.
public final class TestHTTPServer: @unchecked Sendable {

    public struct Request: Sendable {
        public var method: String
        public var path: String
        /// Lowercased names. Repeated fields are joined with ", " exactly as a real server would
        /// see them after Foundation has combined them.
        public var headers: [String: String]
        /// Every raw header line, so a test can see whether a field arrived twice.
        public var rawHeaderLines: [String]
        public var body: Data
    }

    public struct Response: Sendable {
        public var status: Int = 200
        public var headers: [String: String] = ["Content-Type": "application/json"]
        public var body: Data = Data()

        public init(
            status: Int = 200,
            headers: [String: String] = ["Content-Type": "application/json"],
            body: Data = Data()
        ) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func json(_ text: String, status: Int = 200) -> Response {
            Response(
                status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8)
            )
        }

        public static func redirect(to location: String, status: Int = 302) -> Response {
            Response(status: status, headers: ["Location": location], body: Data())
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.nib.test-server")
    private let lock = NSLock()
    private var handler: @Sendable (Request) -> Response
    private var _received: [Request] = []

    public var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// Every request the server has seen, in order. This is how the fidelity tests inspect what
    /// Foundation really sent.
    public var received: [Request] {
        lock.withLock { _received }
    }

    public init(handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port 0 asks the kernel for a free port, so parallel test suites cannot collide.
        listener = try NWListener(using: parameters, on: .any)
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(
                domain: "TestHTTPServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
    }

    public func stop() {
        listener.cancel()
    }

    public var baseURL: String { "http://127.0.0.1:\(port)" }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            if error != nil {
                connection.cancel()
                return
            }

            // Wait for the full head, then for Content-Length bytes of body.
            if let request = Self.parse(accumulated) {
                let response = self.lock.withLock {
                    self._received.append(request)
                    return self.handler(request)
                }
                self.send(response, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(connection, buffer: accumulated)
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        connection.send(
            content: payload,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Parsing

    private static let headTerminator = Data("\r\n\r\n".utf8)

    private static func parse(_ data: Data) -> Request? {
        guard let headEnd = data.range(of: headTerminator) else { return nil }

        let headData = data[data.startIndex..<headEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            // Repeated fields join with ", ", matching how any server sees them.
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let expected = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= expected else { return nil }

        let bodyEnd = data.index(bodyStart, offsetBy: expected)
        return Request(
            method: parts[0],
            path: parts[1],
            headers: headers,
            rawHeaderLines: lines.filter { !$0.isEmpty },
            body: Data(data[bodyStart..<bodyEnd])
        )
    }

    // A flat lookup table of status reason phrases. Branch count is high; complexity is not.
    // Note: the disable directive must be the line immediately above the declaration -- putting
    // an explanatory comment between the two silently applies it to the comment instead.
    // swiftlint:disable:next cyclomatic_complexity
    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
