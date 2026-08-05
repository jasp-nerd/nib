import Foundation
import NibCore
import Testing

@testable import NibUI

/// The two transformations between "what arrived" and "what is on screen": hard-wrapping, and
/// recovering cookies that `allHeaderFields` merged together.
@Suite("Response presentation")
struct ResponsePresentationTests {

    // MARK: - Splitting merged Set-Cookie headers

    /// The exact string a real server produced, joined by `HTTPURLResponse.allHeaderFields`.
    /// Foundation on its own returned one cookie from this, and not the first one.
    @Test("a joined pair splits back into two, despite the comma in the date")
    func splitsAroundExpiresComma() {
        let joined =
            "session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax, "
            + "tracking=xyz; Path=/api; Expires=Wed, 21 Oct 2026 07:28:00 GMT"

        let parts = ResponseViewModel.splitJoinedCookies(joined)

        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("session=abc123"))
        #expect(parts[1].hasPrefix("tracking=xyz"))
        // The date must have survived intact -- splitting inside it is the bug being guarded.
        #expect(parts[1].contains("Expires=Wed, 21 Oct 2026 07:28:00 GMT"))
    }

    @Test("a single cookie is returned unchanged")
    func singleCookie() {
        let one = "session=abc123; Path=/; HttpOnly"
        #expect(ResponseViewModel.splitJoinedCookies(one) == [one])
    }

    @Test("a single cookie containing a date is not split")
    func singleCookieWithDate() {
        let one = "a=1; Expires=Tue, 01 Jan 2030 00:00:00 GMT"
        #expect(ResponseViewModel.splitJoinedCookies(one) == [one])
    }

    @Test("three cookies split into three")
    func threeCookies() {
        let joined = "a=1; Path=/, b=2; Path=/, c=3; Expires=Fri, 02 Feb 2029 00:00:00 GMT"
        #expect(ResponseViewModel.splitJoinedCookies(joined).count == 3)
    }

    /// A comma inside a value, with no `name=` after it, belongs to the cookie being read.
    @Test("a comma inside a value does not start a new cookie")
    func commaInsideValue() {
        let one = "prefs=dark,compact,wide; Path=/"
        #expect(ResponseViewModel.splitJoinedCookies(one) == [one])
    }

    @Test(
        "degenerate input produces no crash and no empty entries",
        arguments: ["", ",", ",,", "   ", "=", "a=", "; ,"]
    )
    func degenerateCookies(header: String) {
        for part in ResponseViewModel.splitJoinedCookies(header) {
            #expect(!part.isEmpty)
        }
    }

    /// End to end through the type, with the headers shaped the way the engine delivers them.
    @Test("both cookies reach the model with their flags intact")
    func cookiesEndToEnd() throws {
        let response = makeResponse(
            headers: [
                SendPlan.Header(
                    name: "Set-Cookie",
                    value: "session=abc123; Path=/; HttpOnly; Secure; SameSite=Lax, "
                        + "tracking=xyz; Path=/api; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
            ],
            body: Data("{}".utf8))

        #expect(response.cookies.map(\.name) == ["session", "tracking"])

        let session = try #require(response.cookies.first)
        #expect(session.isSecure)
        #expect(session.isHTTPOnly)
        #expect(session.path == "/")
        #expect(session.expires == nil)  // a session cookie

        let tracking = try #require(response.cookies.last)
        #expect(!tracking.isSecure)
        #expect(tracking.expires != nil)
    }

    /// Foundation drops a `Secure` cookie parsed against an `http://` URL, silently. For a browser
    /// that is right; for a tab whose job is "show me what the response set" it is the least useful
    /// possible answer, so the cookie is shown and flagged instead.
    @Test("a Secure cookie over plain HTTP is shown and flagged, not dropped")
    func secureCookieOverPlainHTTP() throws {
        let response = ResponseViewModel(
            result: SendEvent.Result(
                head: SendEvent.ResponseHead(
                    status: 200,
                    headers: [
                        SendPlan.Header(
                            name: "Set-Cookie", value: "session=abc; Path=/; Secure"),
                        SendPlan.Header(name: "Set-Cookie", value: "plain=1; Path=/"),
                    ],
                    expectedLength: nil),
                payload: .memory(Data("{}".utf8)),
                timing: SendEvent.Timing(total: .milliseconds(1))
            ),
            requestURL: URL(string: "http://127.0.0.1:8795/user").unsafelyUnwrapped)

        #expect(response.cookies.map(\.name) == ["session", "plain"])
        #expect(try #require(response.cookies.first).isDiscardedAsInsecure)
        #expect(try #require(response.cookies.last).isDiscardedAsInsecure == false)
    }

    @Test("over https a Secure cookie is not flagged")
    func secureCookieOverHTTPS() throws {
        let response = makeResponse(
            headers: [SendPlan.Header(name: "Set-Cookie", value: "session=abc; Path=/; Secure")],
            body: Data("{}".utf8))
        #expect(try #require(response.cookies.first).isDiscardedAsInsecure == false)
    }

    @Test("a response with no Set-Cookie has no cookies")
    func noCookies() {
        #expect(makeResponse(headers: [], body: Data("{}".utf8)).cookies.isEmpty)
    }

    // MARK: - Hard wrapping

    @Test("text under the limit is returned unchanged")
    func shortTextUntouched() {
        let text = "line one\nline two"
        #expect(ResponseViewModel.hardWrapping(text, at: 100) == text)
    }

    @Test("a long line is broken into chunks of at most the limit")
    func longLineWrapped() {
        let line = String(repeating: "a", count: 250)
        let wrapped = ResponseViewModel.hardWrapping(line, at: 100)
        let lines = wrapped.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.utf16.count <= 100 })
        // Nothing may be lost or invented.
        #expect(lines.joined() == line)
    }

    @Test("short lines beside a long one keep their own boundaries")
    func mixedLines() {
        let text = "short\n" + String(repeating: "b", count: 150) + "\nalso short"
        let lines = ResponseViewModel.hardWrapping(text, at: 100)
            .split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.first == "short")
        #expect(lines.last == "also short")
        #expect(lines.count == 4)
    }

    /// Splitting on UTF-16 offsets would cut a surrogate pair in half and put replacement
    /// characters into the middle of somebody's payload.
    @Test("wrapping never splits a surrogate pair")
    func surrogateSafety() {
        // Each emoji is two UTF-16 units, so a limit of 5 lands mid-character if done naively.
        let text = String(repeating: "🎉", count: 20)
        let wrapped = ResponseViewModel.hardWrapping(text, at: 5)

        #expect(!wrapped.unicodeScalars.contains { $0 == "\u{FFFD}" })
        #expect(wrapped.replacingOccurrences(of: "\n", with: "") == text)
    }

    @Test("an empty string survives")
    func emptyText() {
        #expect(ResponseViewModel.hardWrapping("", at: 10).isEmpty)
    }

    // MARK: - Helpers

    private func makeResponse(headers: [SendPlan.Header], body: Data) -> ResponseViewModel {
        ResponseViewModel(
            result: SendEvent.Result(
                head: SendEvent.ResponseHead(status: 200, headers: headers, expectedLength: nil),
                payload: .memory(body),
                timing: SendEvent.Timing(total: .milliseconds(1))
            ),
            // A concrete URL matters: `HTTPCookie` rejects a cookie whose domain does not match.
            requestURL: URL(string: "https://api.example.com/users").unsafelyUnwrapped
        )
    }
}
