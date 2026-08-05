import Foundation
import NibCore

// swiftlint:disable discouraged_optional_boolean
// These types mirror Postman's schema field for field, and there `disabled` being absent is not the
// same statement as `disabled: false` -- callers test `!= true` precisely so an absent field keeps the
// schema's default. Collapsing them to non-optional Bool here would bake our interpretation into the
// parse rather than the mapping, which is where it belongs.

/// Postman Collection v2.1 (and v2.0), as it actually appears in the wild.
///
/// Schema: `https://schema.postman.com/json/collection/v2.1.0/collection.json`. Exported files carry
/// `info.schema` pointing at either `schema.postman.com` or the older `schema.getpostman.com`, so
/// detection matches on the **path suffix**, never the host.
///
/// Almost every field below has a hand-written `init(from:)`, and that is the whole point of this
/// file. The schema is polymorphic in a dozen places — `url` is a string *or* an object, `header` is
/// an array *or* a raw blob, `description` is a string *or* an object, `script.exec` is a string *or*
/// an array of lines, `host` and `path` are strings *or* arrays — and a naive `Codable` conformance
/// throws on the first real-world file it meets. Every one of these was chosen by Postman, not by us.
///
/// Nothing here maps to Nib's model; that is `PostmanCollectionImporter`'s job. Keeping the two apart
/// means the parsing can be tested against a fixture corpus without any of the mapping in the way.
// swiftlint:disable:next type_body_length
enum Postman {

    // MARK: - Root

    struct Collection: Decodable {
        var info: Info
        var item: [Item]
        var variable: [Variable]?
        var auth: Auth?
        var event: [Event]?
        var protocolProfileBehavior: [String: JSONValue]?
    }

    struct Info: Decodable {
        var name: String
        var schema: String?
        var description: Description?
        var postmanID: String?

        private enum CodingKeys: String, CodingKey {
            case name, schema, description
            case postmanID = "_postman_id"
        }
    }

    // MARK: - Items
    //
    // A single `item` array holds both requests and folders, told apart by which key is present:
    // a folder has `item`, a request has `request`. There is no discriminator field.

    struct Item: Decodable {
        var name: String?
        var request: Request?
        /// Present on folders.
        var item: [Item]?
        var auth: Auth?
        var event: [Event]?
        var variable: [Variable]?
        var description: Description?
        var protocolProfileBehavior: [String: JSONValue]?

        var isFolder: Bool { item != nil }
    }

    // MARK: - Request

    struct Request: Decodable {
        var method: String?
        var url: URLSpec?
        var header: [Header]?
        var body: Body?
        var auth: Auth?
        var description: Description?

        private enum CodingKeys: String, CodingKey {
            case method, url, header, body, auth, description
        }

        init(from decoder: any Decoder) throws {
            // A request can be a bare URL string: `"request": "https://example.com"`.
            if let single = try? decoder.singleValueContainer(),
                let urlString = try? single.decode(String.self)
            {
                method = "GET"
                url = URLSpec(raw: urlString)
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            url = try container.decodeIfPresent(URLSpec.self, forKey: .url)
            header = try Self.decodeHeaders(from: container)
            body = try container.decodeIfPresent(Body.self, forKey: .body)
            auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
            description = try container.decodeIfPresent(Description.self, forKey: .description)
        }

        /// `header` is normally an array, but the schema also allows a single raw string holding the
        /// whole block, newline-separated. Both appear in exports.
        private static func decodeHeaders(
            from container: KeyedDecodingContainer<CodingKeys>
        ) throws -> [Header]? {
            if let array = try? container.decodeIfPresent([Header].self, forKey: .header) {
                return array
            }
            guard let blob = try? container.decodeIfPresent(String.self, forKey: .header) else {
                return nil
            }
            return blob.split(separator: "\n").compactMap { line in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return Header(
                    key: String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                    value: String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces),
                    disabled: false)
            }
        }
    }

    struct Header: Decodable {
        var key: String
        var value: String?
        var disabled: Bool?
        var description: Description?

        private enum CodingKeys: String, CodingKey { case key, value, disabled, description }

        init(key: String, value: String?, disabled: Bool?) {
            self.key = key
            self.value = value
            self.disabled = disabled
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decode(String.self, forKey: .key)
            // `value` is usually a string but can be a number or bool.
            if let raw = try? container.decodeIfPresent(JSONValue.self, forKey: .value) {
                value = raw.coercedString
            }
            disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
            description = try? container.decodeIfPresent(Description.self, forKey: .description)
        }
    }

    // MARK: - URL
    //
    // The single most polymorphic field in the schema. It is either a plain string, or an object whose
    // `host` and `path` are *themselves* either strings or arrays of segments.

    struct URLSpec: Decodable {
        var raw: String?
        var host: [String]?
        var path: [String]?
        var query: [QueryParam]?
        var variable: [Variable]?
        var urlProtocol: String?
        var port: String?
        var hash: String?

        init(raw: String) {
            self.raw = raw
        }

        private enum CodingKeys: String, CodingKey {
            case raw, host, path, query, variable, port, hash
            case urlProtocol = "protocol"
        }

        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
                let string = try? single.decode(String.self)
            {
                raw = string
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            raw = try? container.decodeIfPresent(String.self, forKey: .raw)
            host = Self.stringList(container, .host)
            path = Self.pathSegments(container)
            query = try? container.decodeIfPresent([QueryParam].self, forKey: .query)
            variable = try? container.decodeIfPresent([Variable].self, forKey: .variable)
            urlProtocol = try? container.decodeIfPresent(String.self, forKey: .urlProtocol)
            hash = try? container.decodeIfPresent(String.self, forKey: .hash)

            if let raw = try? container.decodeIfPresent(JSONValue.self, forKey: .port) {
                port = raw.coercedString
            }
        }

        /// A field that is either `"a.b.c"` or `["a", "b", "c"]`.
        private static func stringList(
            _ container: KeyedDecodingContainer<CodingKeys>,
            _ key: CodingKeys
        ) -> [String]? {
            if let array = try? container.decodeIfPresent([String].self, forKey: key) {
                return array
            }
            if let single = try? container.decodeIfPresent(String.self, forKey: key) {
                return single.split(separator: ".").map(String.init)
            }
            return nil
        }

        /// `path` adds a third shape: an array of *objects* with a `value`, for path variables.
        private static func pathSegments(
            _ container: KeyedDecodingContainer<CodingKeys>
        ) -> [String]? {
            if let array = try? container.decodeIfPresent([String].self, forKey: .path) {
                return array
            }
            if let single = try? container.decodeIfPresent(String.self, forKey: .path) {
                return single.split(separator: "/").map(String.init)
            }
            if let objects = try? container.decodeIfPresent([JSONValue].self, forKey: .path) {
                return objects.compactMap { $0.coercedString ?? $0["value"]?.coercedString }
            }
            return nil
        }

        /// Rebuild a URL string.
        ///
        /// Prefers `raw`, because that is what the user typed and it preserves `{{variables}}` exactly.
        /// The component form is only assembled when `raw` is missing.
        var reconstructed: String {
            if let raw, !raw.isEmpty { return raw }

            var result = ""
            if let urlProtocol, !urlProtocol.isEmpty { result += urlProtocol + "://" }
            if let host { result += host.joined(separator: ".") }
            if let port, !port.isEmpty { result += ":" + port }
            if let path, !path.isEmpty { result += "/" + path.joined(separator: "/") }

            let active = (query ?? []).filter { $0.disabled != true }
            if !active.isEmpty {
                result +=
                    "?"
                    + active.map { "\($0.key ?? "")=\($0.value ?? "")" }.joined(separator: "&")
            }
            if let hash, !hash.isEmpty { result += "#" + hash }
            return result
        }
    }

    struct QueryParam: Decodable {
        var key: String?
        var value: String?
        var disabled: Bool?

        private enum CodingKeys: String, CodingKey { case key, value, disabled }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try? container.decodeIfPresent(String.self, forKey: .key)
            if let raw = try? container.decodeIfPresent(JSONValue.self, forKey: .value) {
                value = raw.coercedString
            }
            disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
        }
    }

    // MARK: - Body

    struct Body: Decodable {
        var mode: String?
        var raw: String?
        var urlencoded: [FormParam]?
        var formdata: [FormParam]?
        var graphql: GraphQL?
        var file: FileBody?
        var options: Options?
        var disabled: Bool?

        struct Options: Decodable {
            var raw: RawOptions?
            struct RawOptions: Decodable { var language: String? }
        }

        struct GraphQL: Decodable {
            var query: String?
            /// A JSON **string** in Postman's format, not an object. Kept verbatim; parsing and
            /// re-serialising it would reformat the user's variables for no reason.
            var variables: String?

            private enum CodingKeys: String, CodingKey { case query, variables }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                query = try? container.decodeIfPresent(String.self, forKey: .query)
                if let string = try? container.decodeIfPresent(String.self, forKey: .variables) {
                    variables = string
                } else if let object = try? container.decodeIfPresent(
                    JSONValue.self, forKey: .variables),
                    let data = try? JSONEncoder().encode(object)
                {
                    // Some exports use an object here despite the schema. Re-serialise so the shape
                    // reaching our model is always the string Postman documents.
                    variables = String(data: data, encoding: .utf8)
                }
            }
        }

        struct FileBody: Decodable {
            var src: String?

            private enum CodingKeys: String, CodingKey { case src }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // `src` can be null for a file the exporter could not include.
                src = try? container.decodeIfPresent(String.self, forKey: .src)
            }
        }
    }

    struct FormParam: Decodable {
        var key: String?
        var value: String?
        var type: String?
        /// A single path, or several for a multi-file field.
        var src: [String]?
        var disabled: Bool?
        var contentType: String?

        private enum CodingKeys: String, CodingKey {
            case key, value, type, src, disabled, contentType
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try? container.decodeIfPresent(String.self, forKey: .key)
            if let raw = try? container.decodeIfPresent(JSONValue.self, forKey: .value) {
                value = raw.coercedString
            }
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
            contentType = try? container.decodeIfPresent(String.self, forKey: .contentType)

            // `src` is a string for one file and an array for several.
            if let array = try? container.decodeIfPresent([String].self, forKey: .src) {
                src = array
            } else if let single = try? container.decodeIfPresent(String.self, forKey: .src) {
                src = [single]
            }
        }
    }

    // MARK: - Auth
    //
    // The payload for each scheme is an **array** of `{key, value, type}` triples, not an object.
    // Getting that wrong silently produces a request with no credentials.

    struct Auth: Decodable {
        var type: String
        /// Flattened from the per-scheme array into a dictionary, which is what callers want.
        var parameters: [String: String]
        /// The raw payload, for the `preserved` block when we cannot execute the scheme.
        var raw: [String: JSONValue]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            let typeKey = DynamicKey("type")
            guard let type = try? container.decode(String.self, forKey: typeKey) else {
                throw DecodingError.dataCorruptedError(
                    forKey: typeKey, in: container, debugDescription: "auth has no type")
            }
            self.type = type

            var raw: [String: JSONValue] = [:]
            for key in container.allKeys {
                if let value = try? container.decode(JSONValue.self, forKey: key) {
                    raw[key.stringValue] = value
                }
            }
            self.raw = raw

            var parameters: [String: String] = [:]
            if let entries = raw[type]?.arrayValue {
                for entry in entries {
                    guard let key = entry["key"]?.stringValue else { continue }
                    parameters[key] = entry["value"]?.coercedString ?? ""
                }
            } else if let object = raw[type]?.objectValue {
                // Not schema-conformant, but it appears in hand-edited files.
                for (key, value) in object {
                    parameters[key] = value.coercedString ?? ""
                }
            }
            self.parameters = parameters
        }
    }

    // MARK: - Events and variables

    struct Event: Decodable {
        var listen: String?
        var script: Script?
        var disabled: Bool?

        struct Script: Decodable {
            /// Source lines. Postman writes either an array of lines or one string.
            var exec: [String]?
            var type: String?
            var src: String?

            private enum CodingKeys: String, CodingKey { case exec, type, src }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let array = try? container.decodeIfPresent([String].self, forKey: .exec) {
                    exec = array
                } else if let single = try? container.decodeIfPresent(String.self, forKey: .exec) {
                    exec = single.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                }
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                src = try? container.decodeIfPresent(String.self, forKey: .src)
            }
        }

        /// Whether the script has any actual content.
        ///
        /// Postman leaves empty `exec: [""]` blocks behind constantly. Reporting those as "preserved
        /// scripts" would cry wolf on almost every import.
        var hasContent: Bool {
            guard let lines = script?.exec else { return false }
            return lines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    struct Variable: Decodable {
        var key: String?
        var value: String?
        var type: String?
        var disabled: Bool?
        var name: String?

        private enum CodingKeys: String, CodingKey { case key, value, type, disabled, name }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try? container.decodeIfPresent(String.self, forKey: .key)
            name = try? container.decodeIfPresent(String.self, forKey: .name)
            if let raw = try? container.decodeIfPresent(JSONValue.self, forKey: .value) {
                value = raw.coercedString
            }
            type = try? container.decodeIfPresent(String.self, forKey: .type)
            disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
        }
    }

    /// `description` is a string in most exports and an object with a `content` field in others.
    struct Description: Decodable {
        var content: String?

        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer() {
                if single.decodeNil() { return }
                if let string = try? single.decode(String.self) {
                    content = string
                    return
                }
            }
            let container = try decoder.container(keyedBy: DynamicKey.self)
            content = try? container.decodeIfPresent(String.self, forKey: DynamicKey("content"))
        }
    }

    // MARK: - Environments

    /// A Postman environment or globals export.
    ///
    /// Told apart from a collection by having `values` and `_postman_variable_scope` and no
    /// `info.schema`.
    struct EnvironmentExport: Decodable {
        var id: String?
        var name: String?
        var values: [Value]
        var scope: String?

        private enum CodingKeys: String, CodingKey {
            case id, name, values
            case scope = "_postman_variable_scope"
        }

        struct Value: Decodable {
            var key: String
            var value: String?
            var type: String?
            var enabled: Bool?

            private enum CodingKeys: String, CodingKey { case key, value, type, enabled }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                key = try container.decode(String.self, forKey: .key)
                if let raw = try? container.decodeIfPresent(JSONValue.self, forKey: .value) {
                    value = raw.coercedString
                }
                type = try? container.decodeIfPresent(String.self, forKey: .type)
                enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
            }

            /// Postman marks a value secret with `type: "secret"`.
            var isSecret: Bool { type == "secret" }
        }
    }
}

/// A `CodingKey` for reading arbitrary keys, used where the key name is data.
struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    /// Non-failable, so reading a key we know the name of needs no force unwrap.
    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
