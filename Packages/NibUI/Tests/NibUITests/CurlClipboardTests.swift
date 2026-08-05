import AppKit
import Foundation
import NibCore
import NibTestSupport
import Testing

@testable import NibUI

/// The Phase 2 demo, as a test: copy-as-cURL out of devtools, paste into Nib, send.
///
/// These touch the real `NSPasteboard`, so they are serialized — two of them running concurrently
/// would fight over the system clipboard.
@Suite("cURL clipboard flow", .serialized)
@MainActor
struct CurlClipboardTests {

    private func setClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    // MARK: - Paste

    @Test("pasting a Chrome cURL command populates the request")
    func pasteChromeCommand() {
        setClipboard(
            """
            curl 'https://api.example.com/v2/users?page=2' \\
              -H 'accept: application/json' \\
              -H 'authorization: Bearer tok_abc' \\
              --data-raw '{"name":"Ada"}'
            """)

        let model = AppModel()
        #expect(model.clipboardHoldsCurlCommand)

        let failure = model.pasteCurlFromClipboard()
        #expect(failure == nil)

        #expect(model.session.spec.method == .post)
        #expect(model.session.spec.url == "https://api.example.com/v2/users?page=2")
        #expect(model.session.spec.headers.count == 2)
        #expect(model.session.canSend)
    }

    @Test("pasting something that is not curl reports why, and leaves the request alone")
    func pasteNonCurl() {
        setClipboard("SELECT * FROM users;")

        let model = AppModel()
        model.session.spec.url = "https://keep.example"

        #expect(!model.clipboardHoldsCurlCommand)
        let failure = model.pasteCurlFromClipboard()
        #expect(failure != nil)
        // The existing request must survive a failed paste.
        #expect(model.session.spec.url == "https://keep.example")
    }

    @Test("pasting a piped command explains the refusal in plain language")
    func pastePipedCommand() throws {
        setClipboard("curl https://api.example.com/users | jq '.[] | .name'")

        let model = AppModel()
        // `try #require`, not `try? #require`: swallowing the failure turns "there was no message
        // at all" into two silently-skipped expectations and a green test.
        let message = try #require(model.pasteCurlFromClipboard())
        #expect(message.contains("pipes"))
        #expect(message.contains("curl part"))
    }

    @Test("import diagnostics land in the request's notes where the user can see them")
    func diagnosticsSurface() {
        setClipboard("curl -x http://proxy:8080 https://api.example.com/users")

        let model = AppModel()
        #expect(model.pasteCurlFromClipboard() == nil)
        #expect(model.session.notes.contains { $0.contains("Proxy") })
    }

    @Test("pasting clears any previous response")
    func pasteClearsResponse() async throws {
        let server = try TestHTTPServer { _ in .json(#"{"ok":true}"#) }
        try server.start()
        defer { server.stop() }

        let model = AppModel()
        model.session.spec.url = server.baseURL
        model.sendCurrentRequest()
        await model.session.inFlight?.value
        #expect(model.session.response != nil)

        setClipboard("curl https://api.example.com/other")
        #expect(model.pasteCurlFromClipboard() == nil)
        // Showing the old response next to a different request would be actively misleading.
        #expect(model.session.response == nil)
    }

    // MARK: - Copy

    @Test("copying puts a runnable command on the clipboard")
    func copyCommand() {
        let model = AppModel()
        model.session.spec = HTTPRequestSpec(
            method: .post,
            url: "https://api.example.com/users",
            headers: [HeaderField(name: "Accept", value: "application/json")],
            body: .raw(text: #"{"a":1}"#, language: .json))

        #expect(model.copyAsCurl(redacted: false) == nil)

        let command = clipboard()
        #expect(command.hasPrefix("curl"))
        #expect(command.contains("-X POST"))
        #expect(command.contains("https://api.example.com/users"))
        #expect(command.contains("--data-raw"))
    }

    @Test("the redacted variant hides the credential but keeps the scheme")
    func copyRedacted() {
        let model = AppModel()
        model.session.spec = HTTPRequestSpec(
            url: "https://api.example.com/me",
            auth: .bearer(token: "tok_do_not_leak"))

        #expect(model.copyAsCurl(redacted: true) == nil)

        let command = clipboard()
        #expect(!command.contains("tok_do_not_leak"))
        #expect(command.contains("Bearer $AUTHORIZATION"))
        #expect(command.contains("export AUTHORIZATION="))
    }

    @Test("copying with no URL reports it instead of writing junk to the clipboard")
    func copyWithoutURL() {
        setClipboard("untouched")
        let model = AppModel()

        let failure = model.copyAsCurl(redacted: false)
        #expect(failure == "Enter a URL first.")
        #expect(clipboard() == "untouched")
    }

    // MARK: - The full loop

    /// Devtools -> Nib -> send -> back out to a command. This is the Phase 2 clip.
    @Test("paste a command, send it, and copy an equivalent command back out")
    func fullRoundTrip() async throws {
        let server = try TestHTTPServer { _ in .json(#"{"received":true}"#, status: 201) }
        try server.start()
        defer { server.stop() }

        setClipboard(
            """
            curl '\(server.baseURL)/users' \\
              -H 'content-type: application/json' \\
              --data-raw '{"name":"Ada"}'
            """)

        let model = AppModel()
        #expect(model.pasteCurlFromClipboard() == nil)

        model.sendCurrentRequest()
        await model.session.inFlight?.value

        let response = try #require(model.session.response)
        #expect(response.status == 201)

        let received = try #require(server.received.first)
        #expect(received.method == "POST")
        #expect(String(data: received.body, encoding: .utf8) == #"{"name":"Ada"}"#)

        // And back out again.
        #expect(model.copyAsCurl(redacted: false) == nil)
        let exported = clipboard()
        #expect(exported.contains("-X POST"))
        #expect(exported.contains(#"{"name":"Ada"}"#))
    }
}
