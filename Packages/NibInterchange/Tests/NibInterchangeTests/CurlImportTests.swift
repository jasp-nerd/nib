import Foundation
import NibCore
import Testing

@testable import NibInterchange

// swiftlint:disable type_body_length
// A long, flat suite of independent cases over one subject. Splitting it would scatter related
// cases for no benefit.

/// The three devtools dialects are the acceptance test for the lexer, so they are real verbatim
/// strings in `Fixtures/curl/` rather than hand-simplified approximations. A fixture that has been
/// tidied up tests the tidying, not the parser.
@Suite("cURL import")
struct CurlImportTests {

    static func fixture(_ name: String) throws -> String {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let url = root.appendingPathComponent("curl").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The three dialects

    @Test("Chrome on macOS")
    func chromeMacOS() throws {
        let parsed = try CurlImporter.parse(try Self.fixture("chrome-macos.txt"))
        let spec = parsed.spec

        #expect(spec.method == .post)  // --data-raw with no -X implies POST
        #expect(spec.url == "https://api.example.com/v2/users?page=2&limit=50")

        #expect(header(spec, "authorization")?.hasPrefix("Bearer eyJhbGci") == true)
        #expect(header(spec, "content-type") == "application/json")
        // A quoted value containing its own double quotes must survive intact.
        #expect(header(spec, "sec-ch-ua") == #""Chromium";v="140", "Not=A?Brand";v="24""#)
        // `priority: u=1, i` contains a comma and an equals sign.
        #expect(header(spec, "priority") == "u=1, i")

        guard case .raw(let body, let language) = spec.body else {
            Issue.record("expected a raw body, got \(spec.body)")
            return
        }
        #expect(language == .json)
        #expect(body.contains(#""name":"Ada Lovelace""#))
    }

    @Test("Firefox")
    func firefox() throws {
        let parsed = try CurlImporter.parse(try Self.fixture("firefox.txt"))
        let spec = parsed.spec

        // -X wins over the POST that a body would otherwise imply.
        #expect(spec.method == .put)
        #expect(spec.url == "https://api.example.com/v2/users/42")
        #expect(header(spec, "Authorization") == "Basic YWRhOmh1bnRlcjI=")
        // --compressed is about curl's behaviour, not the request; no diagnostic noise for it.
        #expect(!parsed.diagnostics.contains { $0.message.contains("compressed") })
    }

    @Test("Chrome Copy as cURL (cmd) on Windows")
    func windowsCmd() throws {
        let text = try Self.fixture("windows-cmd.txt")
        #expect(ShellLexer.Dialect.detect(in: text) == .windowsCmd)

        let parsed = try CurlImporter.parse(text)
        let spec = parsed.spec

        #expect(spec.method == .post)
        #expect(spec.url == "https://api.example.com/v2/search?q=hello%20world")
        #expect(header(spec, "authorization") == "Bearer tok_windows_123")
        // ^%^ is cmd's escape for a literal %.
        #expect(header(spec, "x-trace") == "a%b")

        guard case .raw(let body, _) = spec.body else {
            Issue.record("expected a raw body, got \(spec.body)")
            return
        }
        // \" inside a cmd-quoted string is a literal quote.
        #expect(body.contains(#"say"#))
        #expect(body.contains("\""))
    }

    @Test("ANSI-C quoting from Chrome")
    func ansiCQuoting() throws {
        let parsed = try CurlImporter.parse(try Self.fixture("chrome-ansi-c.txt"))
        let spec = parsed.spec

        #expect(header(spec, "x-multiline") == "line1\nline2")
        #expect(header(spec, "x-tab") == "a\tb")
    }

    // MARK: - Bodies and method inference

    @Test("a form upload becomes multipart, reported as not-yet-sendable")
    func formUpload() throws {
        let parsed = try CurlImporter.parse(try Self.fixture("form-upload.txt"))
        let spec = parsed.spec

        #expect(spec.method == .post)
        guard case .multipart(let parts) = spec.body else {
            Issue.record("expected multipart, got \(spec.body)")
            return
        }
        #expect(parts.count == 2)
        #expect(parts.first?.content == .file(path: "/tmp/pic.png"))
        #expect(parts.last?.content == .text("hello"))

        // -u becomes structured auth, not a raw header, so it round-trips and shows in the Auth tab.
        #expect(spec.auth == .basic(username: "ada", password: "hunter2"))

        // Never silently dropped: the user is told multipart will not send yet.
        #expect(parsed.diagnostics.contains { $0.message.contains("Multipart") })
    }

    @Test("-G moves data into the query string and keeps the method GET")
    func getWithData() throws {
        let parsed = try CurlImporter.parse(try Self.fixture("get-with-data.txt"))
        let spec = parsed.spec

        #expect(spec.method == .get)
        #expect(spec.url.contains("q=swift"))
        #expect(spec.url.contains("lang=en"))
        #expect(spec.body == .none)
        #expect(!spec.settings.verifyTLS)  // -k
        #expect(spec.settings.maximumRedirects == 3)
        #expect(parsed.diagnostics.contains { $0.message.contains("TLS verification is off") })
    }

    @Test(
        "method inference",
        arguments: [
            ("curl https://x.example", HTTPMethod.get),
            ("curl -d 'a=1' https://x.example", .post),
            ("curl -X PATCH -d 'a=1' https://x.example", .patch),
            ("curl -I https://x.example", .head),
            ("curl -X DELETE https://x.example", .delete),
            ("curl -T /tmp/f.bin https://x.example", .put),
            ("curl -X PROPFIND https://x.example", HTTPMethod("PROPFIND")),
        ]
    )
    func methodInference(command: String, expected: HTTPMethod) throws {
        #expect(try CurlImporter.parse(command).spec.method == expected)
    }

    @Test("--json sets both content type and accept")
    func jsonShorthand() throws {
        let spec = try CurlImporter.parse(
            #"curl --json '{"a":1}' https://x.example"#
        ).spec
        #expect(spec.method == .post)
        #expect(header(spec, "Content-Type") == "application/json")
        #expect(header(spec, "Accept") == "application/json")
    }

    @Test("repeated -d flags are joined with &")
    func repeatedData() throws {
        let spec = try CurlImporter.parse("curl -d 'a=1' -d 'b=2' https://x.example").spec
        guard case .raw(let body, _) = spec.body else {
            Issue.record("expected a raw body")
            return
        }
        #expect(body == "a=1&b=2")
    }

    @Test("--data-urlencode produces a form-encoded body")
    func dataUrlEncode() throws {
        let spec = try CurlImporter.parse(
            "curl --data-urlencode 'q=hello world' https://x.example"
        ).spec
        guard case .urlEncoded(let fields) = spec.body else {
            Issue.record("expected urlEncoded, got \(spec.body)")
            return
        }
        #expect(fields.first?.name == "q")
        #expect(fields.first?.value == "hello world")
    }

    @Test("a body on a method that does not carry one sets sendBodyOnGet, as curl would")
    func bodyOnGetPreserved() throws {
        let spec = try CurlImporter.parse("curl -X GET -d 'a=1' https://x.example").spec
        #expect(spec.method == .get)
        #expect(spec.settings.sendBodyOnGet)
    }

    // MARK: - Flags with values must not be mistaken for the URL

    @Test(
        "output flags that take a value consume it",
        arguments: [
            "curl -o /tmp/out.json https://x.example",
            "curl -w '%{http_code}' https://x.example",
            "curl --retry 3 https://x.example",
        ]
    )
    func outputFlagsConsumeValues(command: String) throws {
        #expect(try CurlImporter.parse(command).spec.url == "https://x.example")
    }

    @Test("--flag=value form is accepted")
    func inlineValues() throws {
        let spec = try CurlImporter.parse(
            "curl --request=DELETE --url=https://x.example --max-redirs=2"
        ).spec
        #expect(spec.method == .delete)
        #expect(spec.url == "https://x.example")
        #expect(spec.settings.maximumRedirects == 2)
    }

    // MARK: - Refusals
    //
    // Silently importing half a command would be worse than refusing it.

    @Test(
        "shell control syntax is refused with an explanation",
        arguments: [
            "curl https://x.example | jq .",
            "curl https://x.example && echo done",
            "curl https://x.example; echo done",
            "curl https://x.example -H \"token: $(cat token.txt)\"",
            "curl https://x.example -H \"token: `cat token.txt`\"",
        ]
    )
    func refusesShellSyntax(command: String) {
        #expect(throws: ShellLexer.LexError.self) {
            _ = try CurlImporter.parse(command)
        }
    }

    @Test("the same characters inside quotes are fine")
    func controlCharactersInQuotesAreFine() throws {
        let spec = try CurlImporter.parse(
            "curl 'https://x.example/a?b=1&c=2' -H 'X-Pipe: a|b' -d 'x=1&y=2'"
        ).spec
        #expect(spec.url == "https://x.example/a?b=1&c=2")
        #expect(header(spec, "X-Pipe") == "a|b")
    }

    @Test("a command with no URL is an error, not an empty request")
    func noURL() {
        #expect(throws: ImportError.self) {
            _ = try CurlImporter.parse("curl -H 'accept: application/json'")
        }
    }

    @Test("an unterminated quote is reported")
    func unterminatedQuote() {
        #expect(throws: ShellLexer.LexError.unterminatedQuote("'")) {
            _ = try CurlImporter.parse("curl 'https://x.example")
        }
    }

    @Test("unsupported auth schemes are reported rather than silently ignored")
    func unsupportedAuth() throws {
        let parsed = try CurlImporter.parse("curl --digest -u a:b https://x.example")
        #expect(parsed.diagnostics.contains { $0.message.contains("digest") })
    }

    @Test("proxy and client-cert flags are reported and their values consumed")
    func reportedFlags() throws {
        let parsed = try CurlImporter.parse(
            "curl -x http://proxy:8080 -E /tmp/c.pem https://x.example")
        #expect(parsed.spec.url == "https://x.example")
        #expect(parsed.diagnostics.contains { $0.message.contains("Proxy") })
        #expect(parsed.diagnostics.contains { $0.message.contains("Client certificates") })
    }

    // MARK: - Sniffing

    @Test(
        "recognises curl commands",
        arguments: [
            ("curl https://x.example", true),
            ("curl.exe \"https://x.example\"", true),
            ("  curl -X GET https://x.example", true),
            ("wget https://x.example", false),
            ("{\"info\":{}}", false),
            ("https://x.example", false),
        ]
    )
    func sniffing(text: String, expected: Bool) {
        #expect(CurlImporter.looksLikeCurl(text) == expected)
    }

    // MARK: - Helper

    private func header(_ spec: HTTPRequestSpec, _ name: String) -> String? {
        spec.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
