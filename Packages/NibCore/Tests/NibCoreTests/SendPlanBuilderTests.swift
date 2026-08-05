import Foundation
import Testing

@testable import NibCore

// swiftlint:disable type_body_length
// A long, flat suite of independent test cases. The limit exists to catch types that have
// grown too many responsibilities; this one has exactly one, and splitting it across two
// structs would scatter related cases for no benefit.
@Suite("SendPlanBuilder")
struct SendPlanBuilderTests {

    private static let scope = VariableScope([
        .environment: [
            "baseUrl": "https://api.acme.dev",
            "token": "tok_123",
            "orgId": "org_9",
        ]
    ])

    private static func build(
        _ spec: HTTPRequestSpec,
        scope: VariableScope = Self.scope,
        inheritedAuth: AuthSpec = .none
    ) throws -> SendPlanBuilder.Output {
        try SendPlanBuilder.build(
            spec, scope: scope, inheritedAuth: inheritedAuth, dynamic: .fixed())
    }

    // MARK: - URL

    @Test("resolves variables in the URL")
    func resolvesURL() throws {
        let out = try Self.build(HTTPRequestSpec(url: "{{baseUrl}}/users"))
        #expect(out.plan.url.absoluteString == "https://api.acme.dev/users")
        #expect(out.isFullyResolved)
    }

    @Test("a missing scheme defaults to https and says so")
    func defaultsScheme() throws {
        let out = try Self.build(HTTPRequestSpec(url: "example.com/users"))
        #expect(out.plan.url.absoluteString == "https://example.com/users")
        #expect(out.notes.contains { $0.contains("assumed https") })
    }

    @Test("an empty URL is an error, not a silent no-op")
    func emptyURLThrows() {
        #expect(throws: SendPlanBuilder.BuildError.emptyURL) {
            _ = try Self.build(HTTPRequestSpec(url: "   "))
        }
    }

    @Test("query params are appended to a URL that already has some")
    func mergesQuery() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/users?page=1",
                params: [Param(name: "limit", value: "50")]
            ))
        let query = try #require(
            URLComponents(url: out.plan.url, resolvingAgainstBaseURL: false)?.query)
        #expect(query.contains("page=1"))
        #expect(query.contains("limit=50"))
    }

    @Test("disabled params are omitted but not lost from the spec")
    func disabledParamsOmitted() throws {
        let spec = HTTPRequestSpec(
            url: "{{baseUrl}}/users",
            params: [
                Param(name: "keep", value: "1"),
                Param(name: "skip", value: "2", enabled: false),
            ])
        let out = try Self.build(spec)
        let query = URLComponents(url: out.plan.url, resolvingAgainstBaseURL: false)?.query ?? ""
        #expect(query.contains("keep=1"))
        #expect(!query.contains("skip"))
        #expect(spec.params.count == 2)  // still there for the UI
    }

    // MARK: - Path parameters
    //
    // The subtle risk here is mistaking the ':' in "https://" or in "host:port" for a parameter.

    @Test("substitutes :name path parameters")
    func pathParams() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/orgs/:orgId/users",
                params: [Param(kind: .path, name: "orgId", value: "{{orgId}}")]
            ))
        #expect(out.plan.url.absoluteString == "https://api.acme.dev/orgs/org_9/users")
    }

    @Test("the colon in the scheme and in host:port is never treated as a parameter")
    func doesNotEatSchemeOrPort() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                url: "http://localhost:8080/orgs/:orgId",
                params: [Param(kind: .path, name: "orgId", value: "abc")]
            ))
        #expect(out.plan.url.absoluteString == "http://localhost:8080/orgs/abc")
    }

    @Test("an unmatched path parameter is left in place and reported")
    func unmatchedPathParam() throws {
        let out = try Self.build(HTTPRequestSpec(url: "{{baseUrl}}/orgs/:orgId"))
        #expect(out.plan.url.absoluteString.contains(":orgId"))
        #expect(out.notes.contains { $0.contains(":orgId") })
    }

    /// A path value must not be able to inject extra segments or start a query string.
    @Test("path parameter values are percent-encoded")
    func pathParamEncoded() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/users/:name",
                params: [Param(kind: .path, name: "name", value: "a/b?c")]
            ))
        let path = out.plan.url.path
        #expect(!path.contains("a/b"))
        #expect(out.plan.url.query == nil)
    }

    // MARK: - Auth

    @Test("bearer auth becomes an Authorization header with the token resolved")
    func bearerAuth() throws {
        let out = try Self.build(
            HTTPRequestSpec(url: "{{baseUrl}}/me", auth: .bearer(token: "{{token}}")))
        #expect(
            out.plan.headers.contains(
                SendPlan.Header(name: "Authorization", value: "Bearer tok_123")))
    }

    @Test("basic auth is base64 of user:password")
    func basicAuth() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/me", auth: .basic(username: "ada", password: "hunter2")))
        // `ada:hunter2`
        #expect(
            out.plan.headers.contains(
                SendPlan.Header(name: "Authorization", value: "Basic YWRhOmh1bnRlcjI=")))
    }

    @Test("an API key can go in a header or the query string")
    func apiKeyPlacement() throws {
        let asHeader = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/me",
                auth: .apiKey(name: "X-Key", value: "{{token}}", placement: .header)))
        #expect(asHeader.plan.headers.contains(SendPlan.Header(name: "X-Key", value: "tok_123")))

        let asQuery = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/me",
                auth: .apiKey(name: "key", value: "{{token}}", placement: .query)))
        #expect(asQuery.plan.url.query?.contains("key=tok_123") == true)
        // Query-string keys end up in server logs. Say so rather than assuming they know.
        #expect(asQuery.notes.contains { $0.contains("query string") })
    }

    @Test("inherit resolves from the folder/collection chain")
    func inheritAuth() throws {
        let out = try Self.build(
            HTTPRequestSpec(url: "{{baseUrl}}/me", auth: .inherit),
            inheritedAuth: .bearer(token: "{{token}}")
        )
        #expect(
            out.plan.headers.contains(
                SendPlan.Header(name: "Authorization", value: "Bearer tok_123")))
    }

    @Test("inherit with nothing to inherit adds no header")
    func inheritNothing() throws {
        let out = try Self.build(HTTPRequestSpec(url: "{{baseUrl}}/me", auth: .inherit))
        #expect(!out.plan.headers.contains { $0.name == "Authorization" })
    }

    // MARK: - Bodies

    @Test("a raw body sets the language's content type")
    func rawBodyContentType() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/users",
                body: .raw(text: #"{"a":1}"#, language: .json)
            ))
        #expect(out.plan.body == .bytes(Data(#"{"a":1}"#.utf8)))
        #expect(
            out.plan.headers.contains(
                SendPlan.Header(name: "Content-Type", value: "application/json")))
    }

    @Test("a user-set Content-Type wins over the default")
    func explicitContentTypeWins() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/users",
                headers: [HeaderField(name: "content-type", value: "application/vnd.acme+json")],
                body: .raw(text: "{}", language: .json)
            ))
        let types = out.plan.headers.filter {
            $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
        }
        #expect(types.count == 1)
        #expect(types.first?.value == "application/vnd.acme+json")
    }

    @Test("variables inside a raw body are resolved")
    func bodyVariables() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/users",
                body: .raw(text: #"{"org":"{{orgId}}"}"#, language: .json)
            ))
        #expect(out.plan.body == .bytes(Data(#"{"org":"org_9"}"#.utf8)))
    }

    /// Form encoding is not query encoding: space becomes `+`, and `&`/`=`/`+` must be escaped.
    @Test("form-urlencoded bodies use form encoding, not query encoding")
    func formEncoding() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/login",
                body: .urlEncoded([
                    Param(name: "q", value: "hello world"),
                    Param(name: "expr", value: "a+b=c&d"),
                ])
            ))
        let body = try #require(bodyString(out.plan.body))
        #expect(body.contains("q=hello+world"))
        #expect(body.contains("a%2Bb%3Dc%26d"))
        #expect(
            out.plan.headers.contains(
                SendPlan.Header(
                    name: "Content-Type", value: "application/x-www-form-urlencoded")))
    }

    @Test("GraphQL variables are embedded as JSON when they parse")
    func graphQLVariablesParsed() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/graphql",
                body: .graphQL(query: "query { me { id } }", variables: #"{"id":7}"#)
            ))
        let body = try #require(bodyString(out.plan.body))
        // An object, not a quoted string.
        #expect(body.contains(#""variables":{"id":7}"#))
    }

    @Test("unparseable GraphQL variables are kept verbatim rather than mangled")
    func graphQLVariablesVerbatim() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/graphql",
                body: .graphQL(query: "query { me }", variables: "not json")
            ))
        let body = try #require(bodyString(out.plan.body))
        #expect(body.contains(#""variables":"not json""#))
    }

    @Test("a binary body becomes a file URL so the engine can stream it")
    func binaryBodyStreams() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-binary-\(UUID().uuidString).bin")
        try Data([0x01, 0x02]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let out = try Self.build(
            HTTPRequestSpec(
                method: .post, url: "{{baseUrl}}/upload", body: .binary(path: file.path)))
        #expect(out.plan.body == .file(file))
        #expect(
            out.plan.headers.contains(
                SendPlan.Header(name: "Content-Type", value: "application/octet-stream")))
    }

    /// A path that does not exist used to build a plan that failed later, inside the engine, as an
    /// opaque URLSession error. Catching it in the builder is the difference between "there is no
    /// file at /tmp/blob.bin" and "-1100".
    @Test("a binary body pointing at nothing is rejected before the request is built")
    func binaryBodyMissingFile() {
        #expect(throws: SendPlanBuilder.BuildError.missingFile("/no/such/blob.bin")) {
            _ = try Self.build(
                HTTPRequestSpec(
                    method: .post, url: "{{baseUrl}}/upload",
                    body: .binary(path: "/no/such/blob.bin")))
        }
    }

    /// Was "multipart is not implemented yet" through Phase 6. `MultipartTests` covers the
    /// assembly in detail; this only pins that the builder no longer refuses it.
    @Test("multipart builds a body and a boundary-carrying content type")
    func multipartBuilds() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/upload",
                body: .multipart([MultipartPart(name: "f", content: .text("x"))])
            ))

        #expect(out.plan.body != SendPlan.Body.none)
        let contentType = try #require(
            out.plan.headers.first {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
            }?.value)
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    }

    // MARK: - Body pruning

    @Test("a body on GET is dropped by default, with a note explaining how to force it")
    func bodyPrunedOnGet() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .get, url: "{{baseUrl}}/search",
                body: .raw(text: "{}", language: .json)))
        #expect(out.plan.body == .none)
        #expect(out.notes.contains { $0.contains("Send body on GET") })
    }

    @Test("sendBodyOnGet keeps it")
    func bodyKeptOnGetWhenAsked() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .get,
                url: "{{baseUrl}}/search",
                body: .raw(text: "{}", language: .json),
                settings: RequestSettings(sendBodyOnGet: true)
            ))
        #expect(out.plan.body == .bytes(Data("{}".utf8)))
    }

    // MARK: - Settings and diagnostics

    @Test("settings carry through to the plan")
    func settingsCarryThrough() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                url: "{{baseUrl}}/x",
                settings: RequestSettings(
                    timeoutMilliseconds: 5000,
                    followRedirects: false,
                    maximumRedirects: 3,
                    verifyTLS: false,
                    preserveMethodOnRedirect: true
                )
            ))
        #expect(out.plan.timeout == .milliseconds(5000))
        #expect(!out.plan.redirects.follow)
        #expect(out.plan.redirects.maximum == 3)
        #expect(out.plan.redirects.preserveMethod)
        #expect(!out.plan.tls.verify)
        #expect(out.notes.contains { $0.contains("TLS") })
    }

    @Test("unresolved variables are collected from every field, not just the URL")
    func unresolvedFromAllFields() throws {
        let out = try Self.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/{{missingPath}}",
                headers: [HeaderField(name: "X-A", value: "{{missingHeader}}")],
                body: .raw(text: "{{missingBody}}", language: .text),
                auth: .bearer(token: "{{missingToken}}")
            ))
        let names = Set(out.unresolved.map(\.name))
        #expect(names == ["missingPath", "missingHeader", "missingBody", "missingToken"])
        // Still sendable: the user gets to see the server's response.
        #expect(!out.isFullyResolved)
    }

    // MARK: - Helper

    private func bodyString(_ body: SendPlan.Body) -> String? {
        guard case .bytes(let data) = body else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
