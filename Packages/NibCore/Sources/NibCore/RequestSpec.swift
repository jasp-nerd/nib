import Foundation

/// A request as the user authored it — templates and all.
///
/// This is the *unresolved* form: `url` may contain `{{variables}}` and `:pathParams`, auth may
/// say `.inherit`, and disabled rows are still present. `SendPlanBuilder` turns it into a
/// `SendPlan`, which is the resolved form the engine sends.
///
/// Everything here is `Codable` because it is also the on-disk format. Keep the coding keys
/// stable; changing one is a format migration.
public struct HTTPRequestSpec: Sendable, Hashable, Codable {
    public var method: HTTPMethod
    /// Template. May contain `{{vars}}` anywhere and `:name` path parameters in the path.
    public var url: String
    public var params: [Param]
    public var headers: [HeaderField]
    public var body: BodySpec
    public var auth: AuthSpec
    public var settings: RequestSettings

    /// Imported data Nib cannot execute — Postman scripts, OAuth 2.0 config, proxy settings.
    ///
    /// Round-tripped untouched through save and load, and reported at import time. This is what makes
    /// "an import never silently drops anything" true, and it makes a future scripts feature purely
    /// additive: the data is already there.
    public var preserved: [String: JSONValue]?

    public init(
        method: HTTPMethod = .get,
        url: String = "",
        params: [Param] = [],
        headers: [HeaderField] = [],
        body: BodySpec = .none,
        auth: AuthSpec = .inherit,
        settings: RequestSettings = .default,
        preserved: [String: JSONValue]? = nil
    ) {
        self.method = method
        self.url = url
        self.params = params
        self.headers = headers
        self.body = body
        self.auth = auth
        self.settings = settings
        self.preserved = preserved
    }
}

/// A query or path parameter.
///
/// Both live in one list because that is how the UI presents them and how Postman stores them,
/// and because a parameter can be moved between the two without losing its value.
public struct Param: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case query
        case path
    }

    public var kind: Kind
    public var name: String
    public var value: String
    /// Disabled rows are kept, not deleted. Toggling one off and on must not lose the value —
    /// that is the whole point of the checkbox.
    public var enabled: Bool

    public init(kind: Kind = .query, name: String, value: String, enabled: Bool = true) {
        self.kind = kind
        self.name = name
        self.value = value
        self.enabled = enabled
    }
}

/// A request header row.
///
/// A pure value type, deliberately with no identity.
///
/// An attempt was made to add a non-encoded `let id: UUID` so SwiftUI's `ForEach($headers)` could key
/// rows stably. It worked for the UI and **crashed the test suite**: the resulting asymmetry — `id`
/// excluded from `CodingKeys`, `Equatable` and `Hashable`, but present as stored state — traps inside
/// Swift Testing's `@Test(arguments:)` machinery when `HTTPRequestSpec` is used as a parameterised
/// argument (`EXC_BREAKPOINT` in `_callBinaryOperator`). The same code paths pass in a plain loop, so
/// it is specific to how the framework derives stable IDs for `Codable` arguments.
///
/// The right conclusion is not to work around the framework: UI identity does not belong in the
/// on-disk model. It would also have put a UUID in every header row on disk, which is diff noise in
/// files whose readability is a selling point. Row identity stays a `NibUI` concern.
public struct HeaderField: Sendable, Hashable, Codable {
    public var name: String
    public var value: String
    public var enabled: Bool

    public init(name: String, value: String, enabled: Bool = true) {
        self.name = name
        self.value = value
        self.enabled = enabled
    }
}

public enum BodySpec: Sendable, Hashable, Codable {
    case none
    case raw(text: String, language: RawLanguage)
    case urlEncoded([Param])
    /// Modelled so Postman imports round-trip, but not yet buildable — see Phase 7.
    case multipart([MultipartPart])
    /// Postman stores GraphQL `variables` as a JSON *string*, not an object. Kept verbatim.
    case graphQL(query: String, variables: String)
    case binary(path: String)

    public enum RawLanguage: String, Sendable, Codable, CaseIterable {
        case json
        case xml
        case html
        case text
        case javascript

        /// The Content-Type we set when the user has not set one themselves.
        public var contentType: String {
            switch self {
            case .json: "application/json"
            case .xml: "application/xml"
            case .html: "text/html"
            case .text: "text/plain"
            case .javascript: "application/javascript"
            }
        }
    }
}

public struct MultipartPart: Sendable, Hashable, Codable {
    public enum Content: Sendable, Hashable, Codable {
        case text(String)
        case file(path: String)
    }

    public var name: String
    public var content: Content
    public var contentType: String?
    public var enabled: Bool

    public init(name: String, content: Content, contentType: String? = nil, enabled: Bool = true) {
        self.name = name
        self.content = content
        self.contentType = contentType
        self.enabled = enabled
    }
}

/// v1 supports exactly these. Everything else Postman offers (OAuth 2.0 flows, AWS SigV4,
/// digest, NTLM, hawk, edgegrid) is imported into `preserved` and reported, never silently
/// dropped — see `ImportDiagnostic`.
public enum AuthSpec: Sendable, Hashable, Codable {
    case none
    /// Resolve from the enclosing folder, then the collection.
    case inherit
    case bearer(token: String)
    case basic(username: String, password: String)
    case apiKey(name: String, value: String, placement: APIKeyPlacement)

    public enum APIKeyPlacement: String, Sendable, Codable {
        case header
        case query
    }
}

public struct RequestSettings: Sendable, Hashable, Codable {
    public var timeoutMilliseconds: Int
    public var followRedirects: Bool
    public var maximumRedirects: Int
    public var verifyTLS: Bool
    /// Postman's `protocolProfileBehavior.disableBodyPruning`, renamed to say what it does.
    /// GET-with-body is a real thing some APIs need, so it is available — just not the default.
    public var sendBodyOnGet: Bool
    /// Re-apply the original method across 301/302/303 instead of letting it become GET.
    public var preserveMethodOnRedirect: Bool

    public init(
        timeoutMilliseconds: Int = 30000,
        followRedirects: Bool = true,
        maximumRedirects: Int = 10,
        verifyTLS: Bool = true,
        sendBodyOnGet: Bool = false,
        preserveMethodOnRedirect: Bool = false
    ) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.followRedirects = followRedirects
        self.maximumRedirects = maximumRedirects
        self.verifyTLS = verifyTLS
        self.sendBodyOnGet = sendBodyOnGet
        self.preserveMethodOnRedirect = preserveMethodOnRedirect
    }

    public static let `default` = RequestSettings()
}

// MARK: - Explicit on-disk encodings
//
// These types are written into the user's git-tracked collection folder, so their JSON shape is a
// documented file format rather than an implementation detail. Swift's synthesized enum encoding
// produces `{"bearer":{"token":"x"}}` — legal, but opaque to a human reading a diff, and it is a
// property of the compiler rather than a decision we made. A `type` discriminator is stable,
// readable, and forward-compatible: an unknown type degrades instead of throwing.

extension AuthSpec {
    private enum CodingKeys: String, CodingKey {
        case type, token, username, password, name, value, placement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "inherit":
            self = .inherit
        case "bearer":
            self = .bearer(token: try container.decodeIfPresent(String.self, forKey: .token) ?? "")
        case "basic":
            self = .basic(
                username: try container.decodeIfPresent(String.self, forKey: .username) ?? "",
                password: try container.decodeIfPresent(String.self, forKey: .password) ?? "")
        case "apiKey":
            self = .apiKey(
                name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
                value: try container.decodeIfPresent(String.self, forKey: .value) ?? "",
                placement: try container.decodeIfPresent(
                    APIKeyPlacement.self, forKey: .placement) ?? .header)
        default:
            // Includes "none" and anything a future version introduces. Degrading to no auth is
            // safer than failing the load: the request still opens and the user can see it.
            self = .none
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .inherit:
            try container.encode("inherit", forKey: .type)
        case .bearer(let token):
            try container.encode("bearer", forKey: .type)
            try container.encode(token, forKey: .token)
        case .basic(let username, let password):
            try container.encode("basic", forKey: .type)
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        case .apiKey(let name, let value, let placement):
            try container.encode("apiKey", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
            try container.encode(placement, forKey: .placement)
        }
    }
}

extension MultipartPart.Content {
    private enum CodingKeys: String, CodingKey { case type, text, path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "file":
            self = .file(path: try container.decodeIfPresent(String.self, forKey: .path) ?? "")
        default:
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .file(let path):
            try container.encode("file", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}
