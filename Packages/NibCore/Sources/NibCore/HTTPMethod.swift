import Foundation

/// An HTTP method.
///
/// Postman collections carry arbitrary method strings, and real APIs use verbs well
/// outside the common set (`PROPFIND`, `LOCK`, `PURGE`). So this is a wrapper over a
/// string rather than a closed enum — an import must never fail because of a verb we
/// did not anticipate.
public struct HTTPMethod: Sendable, Hashable, RawRepresentable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        // Method tokens are case-sensitive per RFC 9110, but every verb in practice is
        // uppercase and Postman exports are inconsistent. Normalise on the way in.
        self.rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    public static let get = HTTPMethod("GET")
    public static let post = HTTPMethod("POST")
    public static let put = HTTPMethod("PUT")
    public static let patch = HTTPMethod("PATCH")
    public static let delete = HTTPMethod("DELETE")
    public static let head = HTTPMethod("HEAD")
    public static let options = HTTPMethod("OPTIONS")

    /// The verbs that get first-class treatment in the method picker. Anything else is
    /// still valid and typeable — it just does not get a menu entry.
    public static let common: [HTTPMethod] = [
        .get, .post, .put, .patch, .delete, .head, .options,
    ]

    /// Whether a body is conventionally sent with this method.
    ///
    /// Only used to pick a sensible default for new requests. It never blocks sending a
    /// body — Postman's `disableBodyPruning` exists precisely because GET-with-body is a
    /// real thing people need, and we carry that through as `RequestSettings.sendBodyOnGet`.
    public var conventionallyCarriesBody: Bool {
        switch self {
        case .post, .put, .patch: true
        default: false
        }
    }
}

extension HTTPMethod: CustomStringConvertible {
    public var description: String { rawValue }
}
