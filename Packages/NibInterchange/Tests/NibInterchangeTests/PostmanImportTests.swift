import Foundation
import NibCore
import Testing

@testable import NibInterchange

// swiftlint:disable type_body_length
// A long, flat suite over one subject.

/// Postman import, driven off real-shaped fixtures.
///
/// Every polymorphic case in `polymorphic.postman_collection.json` is a shape the schema genuinely
/// allows and that a naive `Codable` conformance throws on. The plan predicted 70% of importer bugs
/// would live in exactly those spots, so they get a fixture each rather than a hand-simplified
/// example that would only test the simplification.
@Suite("Postman import")
struct PostmanImportTests {

    static func fixture(_ name: String) throws -> Data {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(
            contentsOf: root.appendingPathComponent("postman").appendingPathComponent(name))
    }

    private func imported(_ name: String) throws -> PostmanCollectionImporter.Imported {
        try PostmanCollectionImporter.importCollection(try Self.fixture(name))
    }

    private func request(
        _ imported: PostmanCollectionImporter.Imported,
        named name: String
    ) throws -> RequestNode {
        try #require(
            imported.collection.allRequests.first { $0.request.name == name }?.request,
            "no request named \(name)")
    }

    // MARK: - Detection

    @Test(
        "recognises collections by schema path, not host",
        arguments: [
            "typical.postman_collection.json",
            "polymorphic.postman_collection.json",
            "legacy-v2.postman_collection.json",
        ]
    )
    func detectsCollections(name: String) throws {
        #expect(PostmanCollectionImporter.looksLikePostmanCollection(try Self.fixture(name)))
    }

    @Test("an environment is not mistaken for a collection, or vice versa")
    func detectionDoesNotOverlap() throws {
        let environment = try Self.fixture("staging.postman_environment.json")
        let collection = try Self.fixture("typical.postman_collection.json")

        #expect(!PostmanCollectionImporter.looksLikePostmanCollection(environment))
        #expect(PostmanEnvironmentImporter.looksLikePostmanEnvironment(environment))

        #expect(PostmanCollectionImporter.looksLikePostmanCollection(collection))
        #expect(!PostmanEnvironmentImporter.looksLikePostmanEnvironment(collection))
    }

    @Test("unrelated JSON is not claimed")
    func rejectsUnrelatedJSON() {
        let data = Data(#"{"hello":"world"}"#.utf8)
        #expect(!PostmanCollectionImporter.looksLikePostmanCollection(data))
        #expect(!PostmanEnvironmentImporter.looksLikePostmanEnvironment(data))
    }

    // MARK: - A typical export

    @Test("the tree, names and order come across")
    func typicalTree() throws {
        let result = try imported("typical.postman_collection.json")

        #expect(result.collection.name == "Acme API")
        #expect(result.collection.children.map(\.name) == ["Auth", "Users"])
        #expect(result.collection.allRequests.count == 4)

        let paths = result.collection.allRequests.map {
            ($0.path.map(\.name) + [$0.request.name]).joined(separator: "/")
        }
        #expect(paths.contains("Auth/Login"))
        #expect(paths.contains("Users/List users"))
    }

    @Test("collection variables and auth come across")
    func typicalCollectionLevel() throws {
        let result = try imported("typical.postman_collection.json")

        #expect(result.collection.auth == .bearer(token: "{{authToken}}"))

        let baseUrl = try #require(result.collection.variables.first { $0.key == "baseUrl" })
        #expect(baseUrl.value == "https://api.acme.dev")
    }

    /// Postman's per-scheme auth payload is an **array** of `{key, value, type}`, not an object.
    /// Reading it as an object yields a request with no credentials and no error.
    @Test("folder auth is read from the array payload")
    func folderAuth() throws {
        let result = try imported("typical.postman_collection.json")
        guard case .folder(let auth) = result.collection.children.first else {
            Issue.record("expected a folder first")
            return
        }
        #expect(auth.auth == .basic(username: "ada", password: "{{pw}}"))
    }

    @Test("headers, including the disabled one, and the raw body")
    func typicalRequest() throws {
        let login = try request(try imported("typical.postman_collection.json"), named: "Login")

        #expect(login.spec.method == .post)
        #expect(login.spec.url == "{{baseUrl}}/{{apiVersion}}/login")

        #expect(login.spec.headers.count == 2)
        let disabled = try #require(login.spec.headers.first { $0.name == "X-Disabled" })
        // Disabled rows are kept, not dropped -- toggling one back on must not need retyping.
        #expect(!disabled.enabled)

        guard case .raw(let body, let language) = login.spec.body else {
            Issue.record("expected a raw body, got \(login.spec.body)")
            return
        }
        #expect(language == .json)
        #expect(body == "{\n  \"user\": \"ada\"\n}")
    }

    /// The reconstructed URL already contains the query string, so query params must not *also* become
    /// params — that would send every one of them twice.
    @Test("query parameters are not duplicated into the params table")
    func queryNotDuplicated() throws {
        let list = try request(try imported("typical.postman_collection.json"), named: "List users")

        #expect(list.spec.url == "{{baseUrl}}/users?page=2&limit=50")
        #expect(list.spec.params.allSatisfy { $0.kind == .path })
    }

    @Test("path variables become path params")
    func pathVariables() throws {
        let get = try request(try imported("typical.postman_collection.json"), named: "Get user")

        #expect(get.spec.url == "{{baseUrl}}/users/:userId")
        let param = try #require(get.spec.params.first)
        #expect(param.kind == .path)
        #expect(param.name == "userId")
        #expect(param.value == "42")
    }

    @Test("form data becomes multipart with file and text parts")
    func formData() throws {
        let upload = try request(
            try imported("typical.postman_collection.json"), named: "Upload avatar")

        guard case .multipart(let parts) = upload.spec.body else {
            Issue.record("expected multipart, got \(upload.spec.body)")
            return
        }
        #expect(parts.count == 2)
        #expect(parts.first?.content == .file(path: "/tmp/pic.png"))
        #expect(parts.last?.content == .text("hello"))
    }

    // MARK: - Polymorphic shapes
    //
    // Each of these is a shape the schema allows and a naive Codable throws on.

    @Test("every polymorphic fixture parses without error")
    func polymorphicParses() throws {
        let result = try imported("polymorphic.postman_collection.json")
        #expect(result.collection.allRequests.count == 9)
    }

    @Test(
        "URL shapes",
        arguments: [
            ("URL as a bare string", "https://example.com/a"),
            ("Request as a bare string", "https://example.com/bare"),
            ("Host and path as strings", "https://example.com:8443/one/two"),
            ("Path as objects", "example.com/x/y"),
        ]
    )
    func urlShapes(name: String, expected: String) throws {
        let node = try request(try imported("polymorphic.postman_collection.json"), named: name)
        #expect(node.spec.url == expected)
    }

    @Test("headers given as one raw blob are split into rows")
    func rawHeaderBlob() throws {
        let node = try request(
            try imported("polymorphic.postman_collection.json"), named: "Headers as a raw blob")
        #expect(node.spec.headers.count == 2)
        #expect(node.spec.headers.first { $0.name == "Accept" }?.value == "application/json")
        #expect(node.spec.headers.first { $0.name == "X-Trace" }?.value == "abc")
    }

    /// Postman writes numbers and bools unquoted for header values, despite the schema.
    @Test("non-string header values are coerced")
    func coercedHeaderValues() throws {
        let node = try request(
            try imported("polymorphic.postman_collection.json"),
            named: "Numeric and bool header values")
        #expect(node.spec.headers.first { $0.name == "X-Count" }?.value == "42")
        #expect(node.spec.headers.first { $0.name == "X-Flag" }?.value == "true")
    }

    @Test("a script given as one string is preserved as lines")
    func scriptAsString() throws {
        let node = try request(
            try imported("polymorphic.postman_collection.json"), named: "Script as one string")
        let preserved = try #require(node.spec.preserved?["postmanEvents"])
        let events = try #require(preserved.arrayValue)
        let lines = try #require(events.first?["exec"]?.arrayValue)
        #expect(lines.count == 2)
        #expect(lines.first?.stringValue == "console.log(1);")
    }

    /// Postman stores GraphQL variables as a JSON *string*. Parsing and re-serialising would reformat
    /// the user's variables for no reason, so it is kept verbatim.
    @Test("GraphQL query and variables come across, variables kept as a string")
    func graphQL() throws {
        let node = try request(
            try imported("polymorphic.postman_collection.json"), named: "GraphQL")
        guard case .graphQL(let query, let variables) = node.spec.body else {
            Issue.record("expected graphQL, got \(node.spec.body)")
            return
        }
        #expect(query == "query { me { id } }")
        #expect(variables == #"{"id":7}"#)
    }

    @Test("an item with no name is named by position rather than dropped")
    func unnamedItem() throws {
        let result = try imported("polymorphic.postman_collection.json")
        // The fixture's ninth item has a name; the point is that nothing was lost.
        #expect(result.collection.allRequests.count == 9)
        #expect(result.collection.allRequests.allSatisfy { !$0.request.name.isEmpty })
    }

    // MARK: - Nothing is silently dropped
    //
    // The invariant that makes the migration hook trustworthy.

    @Test("unsupported auth is reported and its configuration preserved")
    func unsupportedAuth() throws {
        let result = try imported("unsupported.postman_collection.json")

        let oauth = try request(result, named: "OAuth 2.0 request")
        // Preserved verbatim, so a future scripts/oauth feature is purely additive.
        let preserved = try #require(oauth.spec.preserved?["postmanAuth"])
        #expect(preserved["type"]?.stringValue == "oauth2")
        #expect(oauth.spec.auth == .none)

        #expect(
            result.diagnostics.contains {
                $0.severity == .preserved && $0.message.contains("oauth2")
            })
        #expect(
            result.diagnostics.contains {
                $0.severity == .preserved && $0.message.contains("awsv4")
            })
    }

    @Test("scripts are preserved and reported, naming the request")
    func scriptsReported() throws {
        let result = try imported("typical.postman_collection.json")

        let login = try request(result, named: "Login")
        #expect(login.spec.preserved?["postmanEvents"] != nil)

        let diagnostic = try #require(
            result.diagnostics.first { $0.message.contains("script") && $0.path.contains("Login") })
        #expect(diagnostic.severity == .preserved)
        #expect(diagnostic.message.contains("not run"))
    }

    /// Postman leaves `exec: [""]` blocks behind constantly. Reporting those would cry wolf on almost
    /// every import and train users to ignore the report.
    @Test("empty script blocks are not reported")
    func emptyScriptsNotReported() throws {
        let result = try imported("typical.postman_collection.json")
        // The collection-level event in the fixture is an empty exec.
        #expect(!result.diagnostics.contains { $0.path == "Acme API" })
    }

    @Test("a binary body with no file path is reported, since Postman never exports file contents")
    func binaryWithoutFile() throws {
        let result = try imported("unsupported.postman_collection.json")
        let node = try request(result, named: "Binary body with no file")
        #expect(node.spec.body == .none)
        #expect(
            result.diagnostics.contains {
                $0.severity == .dropped && $0.message.contains("Re-attach")
            })
    }

    @Test("disableBodyPruning becomes sendBodyOnGet")
    func bodyPruning() throws {
        let node = try request(
            try imported("unsupported.postman_collection.json"),
            named: "GET with body pruning disabled")
        #expect(node.spec.method == .get)
        #expect(node.spec.settings.sendBodyOnGet)
        // And the behaviour block itself round-trips.
        #expect(node.spec.preserved?["protocolProfileBehavior"] != nil)
    }

    @Test("an item that is neither folder nor request is reported, not silently skipped")
    func neitherFolderNorRequest() throws {
        let result = try imported("unsupported.postman_collection.json")
        #expect(
            result.diagnostics.contains {
                $0.severity == .dropped && $0.message.contains("neither")
            })
    }

    // MARK: - Versions and errors

    @Test("v2.0 collections import")
    func legacyVersion() throws {
        let result = try imported("legacy-v2.postman_collection.json")
        #expect(result.collection.name == "Legacy")
        #expect(result.collection.allRequests.count == 1)
    }

    @Test("malformed JSON produces a message naming where it went wrong")
    func malformedReportsLocation() {
        let data = Data(
            #"{"info":{"schema":"x/collection/v2.1.0/collection.json"},"item":[]}"#.utf8)
        #expect(throws: ImportError.self) {
            _ = try PostmanCollectionImporter.importCollection(data)
        }
    }

    @Test("not-JSON is refused")
    func notJSON() {
        #expect(throws: ImportError.self) {
            _ = try PostmanCollectionImporter.importCollection(Data("nonsense".utf8))
        }
    }

    // MARK: - Environments

    @Test("an environment imports, with secrets flagged")
    func environment() throws {
        let result = try PostmanEnvironmentImporter.importEnvironment(
            try Self.fixture("staging.postman_environment.json"))

        #expect(result.environment.name == "Staging")
        #expect(result.environment.variables.count == 3)

        let token = try #require(result.environment.variables.first { $0.key == "authToken" })
        #expect(token.secret)
        // The value is carried in memory; the store strips it before writing.
        #expect(token.value == "eyJhbGciOiJIUzI1NiJ9.secret")

        let unused = try #require(result.environment.variables.first { $0.key == "unused" })
        #expect(!unused.enabled)

        #expect(result.diagnostics.contains { $0.message.contains("Keychain") })
    }

    @Test("a globals export gets a sensible name")
    func globals() throws {
        let result = try PostmanEnvironmentImporter.importEnvironment(
            try Self.fixture("globals.postman_globals.json"))
        #expect(result.environment.name == "Globals")
        #expect(result.environment.variables.first?.key == "globalKey")
    }

    // MARK: - Round trip through the store
    //
    // Import then save then load must not lose the preserved block, or "lossless" is a lie.

    @Test("preserved data survives a save and load")
    func preservedRoundTripsThroughDisk() throws {
        let result = try imported("unsupported.postman_collection.json")
        let oauth = try request(result, named: "OAuth 2.0 request")
        let before = try #require(oauth.spec.preserved)

        // Encode and decode the spec the way the store does.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(before)
        let after = try JSONDecoder().decode([String: JSONValue].self, from: data)

        #expect(after == before)
    }

    /// Whole numbers must not come back as `1.0`, or every save churns the diff.
    @Test("preserved numbers keep their integer shape")
    func preservedNumbersStayIntegers() throws {
        let value: [String: JSONValue] = ["n": .number(1), "big": .number(1_700_000_000)]
        let data = try JSONEncoder().encode(value)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("1.0"))
        #expect(text.contains("1700000000"))
    }
}
