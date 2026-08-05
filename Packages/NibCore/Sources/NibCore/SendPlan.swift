import Foundation

/// A fully-resolved request, ready to put on the wire.
///
/// INVARIANT: by the time a `SendPlan` exists, every `{{variable}}` is gone. The URL is
/// absolute, headers are final, and the body is either bytes or a file to stream.
/// `NibHTTP` therefore has no knowledge of environments, variable layers, or collections.
///
/// That separation is the reason the engine is testable: a `SendPlan` can be built by hand
/// in a test and fired at a localhost echo server, with no store and no UI in the picture.
public struct SendPlan: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL

    /// Ordered, and duplicates are preserved as separate entries.
    ///
    /// Note that URLSession cannot actually emit two header lines with the same name --
    /// `addValue(_:forHTTPHeaderField:)` comma-joins them -- and it reserves several fields
    /// it sets itself. We keep the user's intent faithfully here and record the deviation
    /// at send time, so `docs/http-fidelity.md` describes what really happened rather than
    /// what we hoped would happen.
    public var headers: [Header]

    public var body: Body
    public var redirects: RedirectPolicy
    public var tls: TLSPolicy
    public var timeout: Duration

    public struct Header: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public enum Body: Sendable, Hashable {
        case none
        case bytes(Data)
        /// Streamed from disk rather than read into memory, so a large upload does not
        /// count against the app's RAM budget.
        case file(URL)
    }

    public struct RedirectPolicy: Sendable, Hashable {
        public var follow: Bool
        public var maximum: Int
        /// URLSession rewrites POST to GET on 301/302/303 by default, matching browsers but
        /// not matching curl's `--location` with `-X POST`. When this is true we re-apply the
        /// original method on each hop, because an API client's user means what they typed.
        public var preserveMethod: Bool

        public init(follow: Bool = true, maximum: Int = 10, preserveMethod: Bool = false) {
            self.follow = follow
            self.maximum = maximum
            self.preserveMethod = preserveMethod
        }

        public static let `default` = RedirectPolicy()
        public static let none = RedirectPolicy(follow: false)
    }

    public struct TLSPolicy: Sendable, Hashable {
        public var verify: Bool

        public init(verify: Bool = true) {
            self.verify = verify
        }

        public static let `default` = TLSPolicy()
        /// Only ever set from an explicit per-request toggle, and the UI says what it means.
        /// Never a default, and never applied silently after a failure.
        public static let insecure = TLSPolicy(verify: false)
    }

    public init(
        method: HTTPMethod,
        url: URL,
        headers: [Header] = [],
        body: Body = .none,
        redirects: RedirectPolicy = .default,
        tls: TLSPolicy = .default,
        timeout: Duration = .seconds(30)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.redirects = redirects
        self.tls = tls
        self.timeout = timeout
    }
}
