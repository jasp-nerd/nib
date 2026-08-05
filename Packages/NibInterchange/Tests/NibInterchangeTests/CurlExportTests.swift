import Foundation
import NibCore
import Testing

@testable import NibInterchange

@Suite("cURL export")
struct CurlExportTests {

    private static let scope = VariableScope.environment([
        "baseUrl": "https://api.example.com",
        "token": "tok_secret_value",
    ])

    private func export(
        _ spec: HTTPRequestSpec,
        style: CurlExporter.Style = .plain
    ) throws -> String {
        try CurlExporter.export(spec, scope: Self.scope, style: style)
    }

    // MARK: - Shape

    @Test("GET omits -X, because GET is curl's default")
    func getOmitsMethod() throws {
        let command = try export(HTTPRequestSpec(url: "{{baseUrl}}/users"))
        #expect(!command.contains("-X"))
        #expect(command.contains("https://api.example.com/users"))
    }

    @Test("a non-default method is stated explicitly")
    func statesMethod() throws {
        let command = try export(HTTPRequestSpec(method: .delete, url: "{{baseUrl}}/users/1"))
        #expect(command.contains("-X DELETE"))
    }

    @Test("variables are resolved, not passed through")
    func resolvesVariables() throws {
        let command = try export(
            HTTPRequestSpec(url: "{{baseUrl}}/me", auth: .bearer(token: "{{token}}")))
        #expect(!command.contains("{{"))
        #expect(command.contains("tok_secret_value"))
    }

    @Test("each header gets its own -H")
    func headersOneEach() throws {
        let command = try export(
            HTTPRequestSpec(
                url: "{{baseUrl}}/x",
                headers: [
                    HeaderField(name: "Accept", value: "application/json"),
                    HeaderField(name: "X-Trace", value: "abc"),
                ]))
        #expect(command.contains("-H 'Accept: application/json'"))
        #expect(command.contains("-H 'X-Trace: abc'"))
    }

    /// `--data-raw`, never plain `--data`: `--data` strips newlines and treats a leading `@` as a
    /// filename, both of which silently corrupt a body.
    @Test("bodies use --data-raw")
    func bodyUsesDataRaw() throws {
        let command = try export(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/users",
                body: .raw(text: "{\n  \"a\": 1\n}", language: .json)))
        #expect(command.contains("--data-raw"))
        #expect(!command.contains("--data '"))
    }

    @Test("a single quote inside a value is escaped so the command stays runnable")
    func escapesSingleQuotes() throws {
        let command = try export(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/x",
                body: .raw(text: #"{"name":"O'Brien"}"#, language: .json)))
        // The POSIX idiom: close, escaped quote, reopen.
        #expect(command.contains(#"'\''"#))
    }

    @Test("settings that differ from curl's defaults are emitted")
    func emitsNonDefaultSettings() throws {
        let command = try export(
            HTTPRequestSpec(
                url: "{{baseUrl}}/x",
                settings: RequestSettings(
                    timeoutMilliseconds: 5000,
                    followRedirects: true,
                    maximumRedirects: 3,
                    verifyTLS: false)))
        #expect(command.contains("--location"))
        #expect(command.contains("--max-redirs 3"))
        #expect(command.contains("--insecure"))
        #expect(command.contains("--max-time 5"))
    }

    @Test("curl's own defaults are not restated")
    func omitsDefaults() throws {
        let command = try export(HTTPRequestSpec(url: "{{baseUrl}}/x"))
        #expect(!command.contains("--max-redirs"))
        #expect(!command.contains("--insecure"))
        #expect(!command.contains("--max-time"))
    }

    // MARK: - Redaction
    //
    // The variant people paste into a GitHub issue. Cheap to build, and it stops a support thread
    // from leaking a bearer token.

    @Test("credentials are replaced with shell variables and an export preamble")
    func redactsCredentials() throws {
        let command = try export(
            HTTPRequestSpec(url: "{{baseUrl}}/me", auth: .bearer(token: "{{token}}")),
            style: .redacted)

        #expect(!command.contains("tok_secret_value"))
        #expect(command.contains("$AUTHORIZATION"))
        #expect(command.contains("export AUTHORIZATION="))
        // The scheme is not secret and is often what someone needs to see to help you.
        #expect(command.contains("Bearer $AUTHORIZATION"))
    }

    @Test(
        "credential-shaped headers are recognised by name",
        arguments: [
            "Authorization", "Cookie", "X-Api-Key", "x-auth-token", "apikey",
        ]
    )
    func recognisesCredentialHeaders(name: String) throws {
        let command = try export(
            HTTPRequestSpec(
                url: "{{baseUrl}}/x",
                headers: [HeaderField(name: name, value: "supersecret")]),
            style: .redacted)
        #expect(!command.contains("supersecret"), "\(name) should have been redacted")
    }

    @Test("ordinary headers survive redaction untouched")
    func ordinaryHeadersNotRedacted() throws {
        let command = try export(
            HTTPRequestSpec(
                url: "{{baseUrl}}/x",
                headers: [HeaderField(name: "Accept", value: "application/json")]),
            style: .redacted)
        #expect(command.contains("Accept: application/json"))
        #expect(!command.contains("export"))
    }

    // MARK: - Round trip
    //
    // The acceptance test from the plan: out of Nib, back in, and the request is the same.

    @Test(
        "export then import reproduces the request",
        arguments: [
            HTTPRequestSpec(method: .get, url: "https://api.example.com/users?page=2"),
            HTTPRequestSpec(
                method: .post,
                url: "https://api.example.com/users",
                headers: [HeaderField(name: "Content-Type", value: "application/json")],
                body: .raw(text: #"{"name":"Ada"}"#, language: .json)),
            HTTPRequestSpec(
                method: .put,
                url: "https://api.example.com/users/1",
                headers: [
                    HeaderField(name: "Accept", value: "application/json"),
                    HeaderField(name: "X-Trace", value: "a,b=c"),
                ],
                body: .raw(text: "plain text body", language: .text)),
            HTTPRequestSpec(
                method: .delete,
                url: "https://api.example.com/users/1",
                settings: RequestSettings(verifyTLS: false)),
        ]
    )
    func roundTrip(original: HTTPRequestSpec) throws {
        let command = try CurlExporter.export(original, scope: VariableScope())
        let reimported = try CurlImporter.parse(command).spec

        #expect(reimported.method == original.method)
        #expect(reimported.url == original.url)
        #expect(reimported.settings.verifyTLS == original.settings.verifyTLS)

        // Headers we set explicitly must all come back. The builder may have added others (a
        // Content-Type derived from the body language), so this is a subset check, not equality.
        for header in original.headers {
            let match = reimported.headers.first {
                $0.name.caseInsensitiveCompare(header.name) == .orderedSame
            }
            #expect(match?.value == header.value, "header \(header.name) did not round-trip")
        }

        if case .raw(let originalBody, _) = original.body {
            guard case .raw(let reimportedBody, _) = reimported.body else {
                Issue.record("body did not round-trip as raw: got \(reimported.body)")
                return
            }
            #expect(reimportedBody == originalBody)
        }
    }

    @Test("a redacted command still round-trips structurally, with placeholder credentials")
    func redactedRoundTripsStructurally() throws {
        let original = HTTPRequestSpec(
            method: .get,
            url: "https://api.example.com/me",
            auth: .bearer(token: "secret"))

        let command = try CurlExporter.export(original, scope: VariableScope(), style: .redacted)
        // Drop the export preamble the way someone pasting the curl line would.
        let curlOnly = command.components(separatedBy: "\n\n").last ?? command
        let reimported = try CurlImporter.parse(curlOnly).spec

        #expect(reimported.url == original.url)
        #expect(reimported.method == .get)
        let authorization = reimported.headers.first {
            $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
        }
        #expect(authorization?.value == "Bearer $AUTHORIZATION")
    }

    @Test("exporting a plan reflects what actually went on the wire")
    func exportsFromPlan() throws {
        let built = try SendPlanBuilder.build(
            HTTPRequestSpec(
                method: .post,
                url: "{{baseUrl}}/users",
                body: .raw(text: "{}", language: .json)),
            scope: Self.scope)

        let command = CurlExporter.export(built.plan)
        // Content-Type was added by the builder, not typed by the user, and the export shows it --
        // which is the point: this is the request as sent.
        #expect(command.contains("Content-Type: application/json"))
        #expect(command.contains("-X POST"))
    }
}

@Suite("cURL export — shell safety")
struct CurlExportShellSafetyTests {
    /// Regression probe: an exported command must survive an actual shell.
    @Test("a URL with multiple query parameters is quoted")
    func multiParamURLIsQuoted() throws {
        let command = try CurlExporter.export(
            HTTPRequestSpec(url: "https://api.example.com/users?page=2&limit=5"),
            scope: VariableScope())
        #expect(command.contains("'https://api.example.com/users?page=2&limit=5'"))
    }
}

@Suite("cURL export — URL credential redaction")
struct CurlExportURLRedactionTests {
    /// Redaction inspected only header names, so an API key in the query string — a supported auth
    /// mode — was printed verbatim by the one variant whose entire purpose is not leaking credentials.
    @Test("an API key in the query string is redacted")
    func queryKeyRedacted() throws {
        let command = try CurlExporter.export(
            HTTPRequestSpec(
                url: "https://api.example.com/data",
                auth: .apiKey(name: "api_key", value: "sk_live_do_not_leak", placement: .query)),
            scope: VariableScope(),
            style: .redacted)

        #expect(!command.contains("sk_live_do_not_leak"))
        #expect(command.contains("$API_KEY"))
        #expect(command.contains("export API_KEY="))
    }

    @Test("userinfo credentials are redacted")
    func userinfoRedacted() throws {
        let command = try CurlExporter.export(
            HTTPRequestSpec(url: "https://ada:hunter2@api.example.com/x"),
            scope: VariableScope(),
            style: .redacted)
        #expect(!command.contains("hunter2"))
        #expect(command.contains("$URL_PASSWORD"))
    }

    @Test("ordinary query parameters are left alone")
    func ordinaryParamsUntouched() throws {
        let command = try CurlExporter.export(
            HTTPRequestSpec(url: "https://api.example.com/x?page=2&limit=5"),
            scope: VariableScope(),
            style: .redacted)
        #expect(command.contains("page=2"))
        #expect(command.contains("limit=5"))
        #expect(!command.contains("export"))
    }

    @Test("the plain variant does not redact")
    func plainKeepsEverything() throws {
        let command = try CurlExporter.export(
            HTTPRequestSpec(
                url: "https://api.example.com/data",
                auth: .apiKey(name: "api_key", value: "sk_live_visible", placement: .query)),
            scope: VariableScope())
        #expect(command.contains("sk_live_visible"))
    }
}
