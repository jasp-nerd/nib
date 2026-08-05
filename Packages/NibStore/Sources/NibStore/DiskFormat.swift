import Foundation
import NibCore

/// The on-disk representations.
///
/// Separate `Codable` structs rather than making the domain models `Codable` directly. That is worth
/// one extra layer: the file format has to stay stable across refactors of the in-memory tree, and
/// the mapping is the place to put migrations. It also keeps `order` — a directory concern — out of
/// the domain model, which has real children in real order.
enum DiskFormat {

    // MARK: - collection.json

    struct CollectionFile: Codable {
        var formatVersion: Int
        var id: String
        var name: String
        /// Child names in display order.
        ///
        /// Stored in the parent rather than as a `seq` field in each child, so reordering three
        /// siblings rewrites one file instead of three. Anything present on disk but missing from
        /// `order` is appended alphabetically — which means copying a file in from Finder just works.
        var order: [String]
        var auth: AuthSpec
        var variables: [EnvironmentVariable]

        init(_ collection: NibCore.Collection) {
            formatVersion = StoreLocations.formatVersion
            id = collection.id.rawValue
            name = collection.name
            order = collection.children.map(\.name)
            auth = collection.auth
            variables = collection.variables
        }
    }

    // MARK: - folder.json

    struct FolderFile: Codable {
        var formatVersion: Int
        var id: String
        var order: [String]
        var auth: AuthSpec
        var variables: [EnvironmentVariable]

        init(_ folder: FolderNode) {
            formatVersion = StoreLocations.formatVersion
            id = folder.id.rawValue
            order = folder.children.map(\.name)
            auth = folder.auth
            variables = folder.variables
        }
    }

    // MARK: - <name>.req.json

    struct RequestFile: Codable {
        var formatVersion: Int
        var id: String
        var method: String
        var url: String
        var params: [Param]
        var headers: [HeaderField]
        var auth: AuthSpec
        var settings: RequestSettings
        var body: BodyFile

        /// Anything imported that Nib cannot execute — Postman scripts, oauth2 config, proxy
        /// settings. Round-tripped untouched so "an import never silently drops anything" is
        /// literally true, and so adding scripts later is a purely additive change.
        var preserved: [String: AnyCodableValue]?

        init(_ request: RequestNode, bodyFilename: String?) {
            formatVersion = StoreLocations.formatVersion
            id = request.id.rawValue
            method = request.spec.method.rawValue
            url = request.spec.url
            params = request.spec.params
            headers = request.spec.headers
            auth = request.spec.auth
            settings = request.spec.settings
            body = BodyFile(request.spec.body, filename: bodyFilename)
        }
    }

    /// The body, with its content in a sibling file rather than inline.
    ///
    /// An escaped 40-line JSON body inside a single string is an unreadable diff, and readable diffs
    /// are the whole reason the store is files at all.
    struct BodyFile: Codable {
        var type: String
        var file: String?
        var language: String?
        var contentType: String?
        /// Only used for shapes that are structured rather than free text.
        var fields: [Param]?
        var parts: [MultipartPart]?
        var graphQLVariables: String?

        init(_ body: BodySpec, filename: String?) {
            switch body {
            case .none:
                type = "none"
            case .raw(_, let language):
                type = "raw"
                file = filename
                self.language = language.rawValue
                contentType = language.contentType
            case .urlEncoded(let fields):
                type = "urlEncoded"
                self.fields = fields
            case .multipart(let parts):
                type = "multipart"
                self.parts = parts
            case .graphQL(_, let variables):
                type = "graphQL"
                file = filename
                graphQLVariables = variables
            case .binary(let path):
                type = "binary"
                file = path
            }
        }

        /// Rebuild a `BodySpec`, given the sibling file's contents where one is expected.
        func body(withContents contents: String?) -> BodySpec {
            switch type {
            case "raw":
                let language = BodySpec.RawLanguage(rawValue: self.language ?? "text") ?? .text
                return .raw(text: contents ?? "", language: language)
            case "urlEncoded":
                return .urlEncoded(fields ?? [])
            case "multipart":
                return .multipart(parts ?? [])
            case "graphQL":
                return .graphQL(query: contents ?? "", variables: graphQLVariables ?? "")
            case "binary":
                return .binary(path: file ?? "")
            default:
                return .none
            }
        }
    }

    // MARK: - <name>.env.json

    struct EnvironmentFile: Codable {
        var formatVersion: Int
        var id: String
        var name: String
        var variables: [EnvironmentVariable]

        init(_ environment: NibCore.Environment) {
            formatVersion = StoreLocations.formatVersion
            id = environment.id.rawValue
            name = environment.name
            variables = environment.variables
        }
    }
}

/// A JSON value of unknown shape, for the `preserved` block.
///
/// Deliberately minimal: it only has to round-trip bytes faithfully, not be pleasant to consume.
/// Nothing in Nib reads inside a preserved block — that is the point.
enum AnyCodableValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Emit whole numbers without a decimal point, so a preserved `1` does not become `1.0`
            // and churn the diff on every save.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
