import Foundation

/// A JSON value of arbitrary shape.
///
/// Exists for one job: carrying imported data we cannot execute, byte-faithfully, so that
/// "an import never silently drops anything" is literally true rather than aspirational.
///
/// Postman collections are full of things Nib does not run — pre-request scripts, test assertions,
/// OAuth 2.0 configuration, proxy settings. Discarding them would mean a round trip through Nib
/// quietly destroys work. Instead they go into a request's `preserved` block, survive save and load
/// untouched, and are reported at import time.
///
/// Deliberately minimal. Nothing in Nib reads *inside* a preserved block; that is the point. It only
/// has to round-trip.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // Emit whole numbers without a decimal point, so a preserved `1` does not come back as
            // `1.0` and churn the diff on every save. Determinism is a hard invariant here.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: - Convenience

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// `Bool?` is the right type here: nil means "this value is not a boolean", which is a different
    /// statement from `false`. A non-optional would have to invent an answer for a string or an array.
    // swiftlint:disable:next discouraged_optional_boolean
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        // Postman writes booleans as strings in places, so "true" has to count.
        case .string(let value): value == "true" ? true : (value == "false" ? false : nil)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// A string, whether the value is a string, a number or a bool.
    ///
    /// Postman is inconsistent about which of the three it uses for the same field, so importers need
    /// one accessor that copes.
    public var coercedString: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            value == value.rounded() ? String(Int64(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }
}
