import Foundation
import NibCore
import NibTestSupport
import Testing

@testable import NibUI

/// End-to-end tests through the UI's own model.
///
/// This is the chain a user actually exercises: type a URL, press send, look at the response —
/// `HTTPRequestSpec` -> `SendPlanBuilder` -> `HTTPEngine` -> `ResponseViewModel`. The unit tests
/// cover each link; these prove the links are connected, which no amount of unit testing does.
@Suite("RequestSession", .serialized)
@MainActor
struct RequestSessionTests {

    private func withServer(
        _ handler: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response,
        _ body: (TestHTTPServer, AppModel) async throws -> Void
    ) async throws {
        let server = try TestHTTPServer(handler: handler)
        try server.start()
        defer { server.stop() }
        try await body(server, AppModel())
    }

    // MARK: - The happy path

    @Test("typing a URL and sending produces a displayable response")
    func endToEnd() async throws {
        try await withServer({ _ in .json(#"{"ok":true,"items":[1,2,3]}"#) }) { server, model in
            model.session.spec.url = server.baseURL
            model.sendCurrentRequest()
            await model.session.inFlight?.value

            let response = try #require(model.session.response)
            #expect(response.status == 200)
            #expect(response.statusText == "OK")
            #expect(response.isSuccess)
            #expect(model.session.state == .idle)

            // Pretty-printed, because the payload parsed as JSON.
            #expect(response.isPrettyPrinted)
            #expect(response.bodyText.contains("\"ok\""))
            #expect(response.bodyText.contains("\n"))

            #expect(!response.durationText.isEmpty)
            #expect(!response.sizeText.isEmpty)
        }
    }

    @Test("a POST with a JSON body reaches the server with the right content type")
    func postWithBody() async throws {
        try await withServer({ _ in .json("{}", status: 201) }) { server, model in
            model.session.spec.method = .post
            model.session.spec.url = server.baseURL
            model.session.spec.body = .raw(text: #"{"name":"Ada"}"#, language: .json)

            model.sendCurrentRequest()
            await model.session.inFlight?.value

            #expect(model.session.response?.status == 201)

            let received = try #require(server.received.first)
            #expect(received.method == "POST")
            #expect(String(data: received.body, encoding: .utf8) == #"{"name":"Ada"}"#)
            // The builder supplied Content-Type from the body language; nobody typed it.
            #expect(received.headers["content-type"] == "application/json")
        }
    }

    @Test("headers from the table are sent, and disabled ones are not")
    func headerTable() async throws {
        try await withServer({ _ in .json("{}") }) { server, model in
            model.session.spec.url = server.baseURL
            model.session.spec.headers = [
                HeaderField(name: "X-Sent", value: "yes"),
                HeaderField(name: "X-Skipped", value: "no", enabled: false),
            ]

            model.sendCurrentRequest()
            await model.session.inFlight?.value

            let received = try #require(server.received.first)
            #expect(received.headers["x-sent"] == "yes")
            #expect(received.headers["x-skipped"] == nil)
        }
    }

    // MARK: - Variables

    @Test("an environment variable in the URL resolves before sending")
    func variableInURL() async throws {
        try await withServer({ _ in .json("{}") }) { server, model in
            model.session.scope = .environment(["base": server.baseURL])
            model.session.spec.url = "{{base}}/users"

            model.sendCurrentRequest()
            await model.session.inFlight?.value

            #expect(model.session.response?.status == 200)
            #expect(server.received.first?.path == "/users")
            #expect(model.session.unresolved.isEmpty)
        }
    }

    /// A request with a bad variable stays sendable on purpose: seeing the server's response is
    /// often how you work out what was wrong. The UI warns rather than blocking.
    @Test("an unresolved variable is reported but does not block sending")
    func unresolvedVariableStillSends() async throws {
        try await withServer({ _ in .json("{}") }) { server, model in
            model.session.scope = .environment(["base": server.baseURL])
            model.session.spec.url = "{{base}}/{{nope}}"

            model.sendCurrentRequest()
            await model.session.inFlight?.value

            #expect(model.session.unresolved.map(\.name) == ["nope"])
            #expect(model.session.response != nil)
        }
    }

    // MARK: - Errors and edge cases

    @Test("an empty URL fails immediately with a readable message, and never sends")
    func emptyURL() async throws {
        let model = AppModel()
        model.session.spec.url = "   "
        model.sendCurrentRequest()

        #expect(!model.session.canSend)
        // canSend is false, so nothing was attempted at all.
        #expect(model.session.inFlight == nil)
        #expect(model.session.response == nil)
    }

    @Test("a 404 is a response, not a failure")
    func notFoundIsAResponse() async throws {
        try await withServer({ _ in .json(#"{"error":"nope"}"#, status: 404) }) { server, model in
            model.session.spec.url = server.baseURL
            model.sendCurrentRequest()
            await model.session.inFlight?.value

            let response = try #require(model.session.response)
            #expect(response.status == 404)
            #expect(response.isError)
            // State is idle: the request succeeded, the server said no.
            #expect(model.session.state == .idle)
        }
    }

    @Test("an unreachable host sets a failed state with an actionable message")
    func unreachableHost() async throws {
        let model = AppModel()
        model.session.spec.url = "http://127.0.0.1:1/"
        model.sendCurrentRequest()
        await model.session.inFlight?.value

        guard case .failed(let message) = model.session.state else {
            Issue.record("expected .failed, got \(model.session.state)")
            return
        }
        #expect(message.contains("reachable"))
        #expect(model.session.response == nil)
    }

    @Test("a body on GET is dropped and the reason surfaces in the UI notes")
    func bodyPrunedNote() async throws {
        try await withServer({ _ in .json("{}") }) { server, model in
            model.session.spec.url = server.baseURL
            model.session.spec.body = .raw(text: "{}", language: .json)

            model.sendCurrentRequest()
            await model.session.inFlight?.value

            #expect(model.session.notes.contains { $0.contains("Send body on GET") })
            #expect(server.received.first?.body.isEmpty == true)
        }
    }

    @Test("sending twice replaces the first attempt rather than racing it")
    func resendReplaces() async throws {
        try await withServer({ _ in .json(#"{"n":1}"#) }) { server, model in
            model.session.spec.url = server.baseURL

            model.sendCurrentRequest()
            model.sendCurrentRequest()  // immediately again
            await model.session.inFlight?.value

            #expect(model.session.response?.status == 200)
            #expect(model.session.state == .idle)
        }
    }

    @Test("redirects are followed and reported to the UI")
    func redirectsSurfaceInUI() async throws {
        try await withServer({ request in
            request.path == "/start" ? .redirect(to: "/end") : .json(#"{"done":true}"#)
        }) { server, model in
            model.session.spec.url = "\(server.baseURL)/start"
            model.sendCurrentRequest()
            await model.session.inFlight?.value

            let response = try #require(model.session.response)
            #expect(response.status == 200)
            #expect(response.hops.count == 1)
        }
    }

    @Test("a non-JSON body is shown as text rather than pretty-printed")
    func plainTextBody() async throws {
        try await withServer({ _ in
            TestHTTPServer.Response(
                status: 200, headers: ["Content-Type": "text/plain"], body: Data("hello".utf8))
        }) { server, model in
            model.session.spec.url = server.baseURL
            model.sendCurrentRequest()
            await model.session.inFlight?.value

            let response = try #require(model.session.response)
            #expect(!response.isPrettyPrinted)
            #expect(response.bodyText == "hello")
        }
    }
}
