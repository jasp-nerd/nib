import Foundation

/// What the engine reports while a request is in flight.
///
/// Modelled as a stream rather than a single completion value so download progress, redirect
/// hops and streaming-to-disk all fall out of one mechanism instead of three callbacks.
public enum SendEvent: Sendable {
    case started
    case redirected(Hop)
    case responseHead(ResponseHead)
    case bodyChunk(received: Int64, expected: Int64?)
    case finished(Result)
    case failed(Failure)

    public struct Hop: Sendable, Hashable {
        public var from: URL
        public var to: URL
        public var status: Int

        public init(from: URL, to: URL, status: Int) {
            self.from = from
            self.to = to
            self.status = status
        }
    }

    public struct ResponseHead: Sendable, Hashable {
        public var status: Int
        public var headers: [SendPlan.Header]
        public var expectedLength: Int64?

        public init(status: Int, headers: [SendPlan.Header], expectedLength: Int64? = nil) {
            self.status = status
            self.headers = headers
            self.expectedLength = expectedLength
        }
    }

    /// Where the response body ended up.
    ///
    /// Bodies stay in memory up to `bodyMemoryLimit` and spill to a temp file above it, so a
    /// 200 MB response cannot blow the RAM budget. The UI memory-maps the file rather than
    /// reading it.
    public enum Payload: Sendable, Hashable {
        case memory(Data)
        case file(URL, byteCount: Int64)
    }

    public struct Result: Sendable, Hashable {
        public var head: ResponseHead
        public var payload: Payload
        public var timing: Timing
        public var hops: [Hop]
        /// h1, h2, h3 -- from `URLSessionTaskMetrics.networkProtocolName`.
        public var networkProtocol: String?
        /// Places where URLSession did not send exactly what was asked for. Surfaced in the
        /// UI rather than hidden, because being the client that documents its deviations is
        /// more useful than pretending there are none.
        public var fidelityNotes: [String]

        public init(
            head: ResponseHead,
            payload: Payload,
            timing: Timing,
            hops: [Hop] = [],
            networkProtocol: String? = nil,
            fidelityNotes: [String] = []
        ) {
            self.head = head
            self.payload = payload
            self.timing = timing
            self.hops = hops
            self.networkProtocol = networkProtocol
            self.fidelityNotes = fidelityNotes
        }
    }

    /// Derived from `URLSessionTaskMetrics.transactionMetrics`. Drives the timing waterfall.
    public struct Timing: Sendable, Hashable {
        public var dns: Duration?
        public var connect: Duration?
        public var tls: Duration?
        public var request: Duration?
        public var timeToFirstByte: Duration?
        public var download: Duration?
        public var total: Duration

        public init(
            dns: Duration? = nil,
            connect: Duration? = nil,
            tls: Duration? = nil,
            request: Duration? = nil,
            timeToFirstByte: Duration? = nil,
            download: Duration? = nil,
            total: Duration
        ) {
            self.dns = dns
            self.connect = connect
            self.tls = tls
            self.request = request
            self.timeToFirstByte = timeToFirstByte
            self.download = download
            self.total = total
        }
    }

    public struct Failure: Sendable, Hashable, Error {
        public enum Kind: Sendable, Hashable {
            case cancelled
            case timedOut
            case cannotConnect
            case dnsFailure
            /// Carries the real `SecTrust` reason so the UI can explain the failure instead
            /// of showing `-1202`.
            case tlsUntrusted(reason: String)
            case tooManyRedirects
            case other(code: Int)
        }

        public var kind: Kind
        public var message: String

        public init(kind: Kind, message: String) {
            self.kind = kind
            self.message = message
        }
    }
}

/// Above this, response bodies spill to a temp file instead of staying in memory.
public let bodyMemoryLimit: Int64 = 8 * 1024 * 1024
