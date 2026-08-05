import Foundation
import NibCore
import NibTestSupport
import Testing

@testable import NibHTTP

/// Engine tests against a real localhost server.
///
/// These are not mocked on purpose. The point of Phase 1's fidelity spike is discovering what
/// Foundation actually sends, and a mock would only confirm our assumptions about it.
// swiftlint:disable type_body_length
// A long, flat suite of independent test cases. The limit exists to catch types that have
// grown too many responsibilities; this one has exactly one, and splitting it across two
// structs would scatter related cases for no benefit.
@Suite("HTTPEngine", .serialized)
struct HTTPEngineTests {

    // MARK: - Harness

    /// A URL from a string we control in the test.
    ///
    /// Deliberately throwing rather than force-unwrapped: a malformed literal should fail the
    /// test with a message, not crash the whole run and take the other cases with it.
    private func requireURL(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// Runs a plan to completion and returns every event.
    private func run(
        _ plan: SendPlan,
        server: TestHTTPServer
    ) async -> [SendEvent] {
        let engine = HTTPEngine()
        var events: [SendEvent] = []
        for await event in engine.send(plan) {
            events.append(event)
        }
        return events
    }

    private func result(_ events: [SendEvent]) -> SendEvent.Result? {
        for event in events {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    private func failure(_ events: [SendEvent]) -> SendEvent.Failure? {
        for event in events {
            if case .failed(let failure) = event { return failure }
        }
        return nil
    }

    private func bodyText(_ payload: SendEvent.Payload) -> String? {
        switch payload {
        case .memory(let data): String(data: data, encoding: .utf8)
        case .file(let url, _): try? String(contentsOf: url, encoding: .utf8)
        }
    }

    private func withServer(
        _ handler: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response,
        _ body: (TestHTTPServer) async throws -> Void
    ) async throws {
        let server = try TestHTTPServer(handler: handler)
        try server.start()
        defer { server.stop() }
        try await body(server)
    }

    // MARK: - The basics

    @Test("a GET returns status, body and timing")
    func simpleGet() async throws {
        try await withServer({ _ in .json(#"{"ok":true}"#) }) { server in
            let plan = SendPlan(
                method: .get, url: try requireURL("\(server.baseURL)/users"))
            let events = await run(plan, server: server)

            let result = try #require(self.result(events))
            #expect(result.head.status == 200)
            #expect(self.bodyText(result.payload) == #"{"ok":true}"#)
            #expect(result.timing.total > .zero)
            #expect(server.received.first?.method == "GET")
            #expect(server.received.first?.path == "/users")
        }
    }

    @Test("events arrive in order and the stream terminates")
    func eventOrder() async throws {
        try await withServer({ _ in .json(#"{"a":1}"#) }) { server in
            let plan = SendPlan(method: .get, url: try requireURL(server.baseURL))
            let events = await run(plan, server: server)

            guard case .started = events.first else {
                Issue.record(
                    "first event should be .started, got \(String(describing: events.first))")
                return
            }
            guard case .finished = events.last else {
                Issue.record(
                    "last event should be .finished, got \(String(describing: events.last))")
                return
            }
        }
    }

    @Test("a POST sends its body and content type")
    func postBody() async throws {
        try await withServer({ _ in .json("{}", status: 201) }) { server in
            let plan = SendPlan(
                method: .post,
                url: try requireURL("\(server.baseURL)/users"),
                headers: [.init(name: "Content-Type", value: "application/json")],
                body: .bytes(Data(#"{"name":"Ada"}"#.utf8))
            )
            let events = await run(plan, server: server)

            #expect(self.result(events)?.head.status == 201)
            let received = try #require(server.received.first)
            #expect(received.method == "POST")
            #expect(String(data: received.body, encoding: .utf8) == #"{"name":"Ada"}"#)
            #expect(received.headers["content-type"] == "application/json")
        }
    }

    @Test("a custom verb reaches the server unchanged")
    func customVerb() async throws {
        try await withServer({ _ in .json("{}") }) { server in
            let plan = SendPlan(
                method: HTTPMethod("PROPFIND"), url: try requireURL(server.baseURL))
            _ = await run(plan, server: server)
            #expect(server.received.first?.method == "PROPFIND")
        }
    }

    // MARK: - Fidelity: what Foundation actually does
    //
    // Each of these documents a real deviation. They assert the CURRENT behaviour so that if a
    // future macOS changes it, we find out from a failing test rather than from a user.

    @Test("Foundation adds headers we never asked for")
    func foundationInjectsHeaders() async throws {
        try await withServer({ _ in .json("{}") }) { server in
            let plan = SendPlan(method: .get, url: try requireURL(server.baseURL))
            _ = await run(plan, server: server)

            let received = try #require(server.received.first)
            // Not requested by us, added by Foundation. Worth knowing about: a server that varies
            // on Accept-Encoding will behave differently than the user expects from reading their
            // own header list.
            #expect(received.headers["accept-encoding"] != nil)
            #expect(received.headers["user-agent"] != nil)
            #expect(received.headers["host"] != nil)
        }
    }

    /// Empirically determine which header fields Foundation refuses to send verbatim.
    ///
    /// This started as an assertion copied from Apple's documented "reserved" list and it was
    /// wrong: `Host` *is* sent verbatim on macOS 26. Rather than assert a list from docs, the test
    /// probes each candidate and prints a table, and `HTTPEngine.reservedHeaderFields` is derived
    /// from the result. When a future macOS changes the behaviour, this fails and tells us which
    /// field moved.
    @Test("probe: which header fields does Foundation actually honour")
    func reservedHeaderProbe() async throws {
        let candidates: [(name: String, value: String)] = [
            ("Host", "spoofed.example"),
            ("Content-Length", "999"),
            ("Connection", "keep-alive"),
            ("Transfer-Encoding", "chunked"),
            ("Authorization", "Bearer probe"),
            ("WWW-Authenticate", "Basic realm=probe"),
            ("Proxy-Authorization", "Bearer probe"),
            ("Accept-Encoding", "identity"),
            ("User-Agent", "nib-probe/1.0"),
            ("Cookie", "probe=1"),
            ("Referer", "https://probe.example"),
            ("X-Ordinary", "kept"),
        ]

        var honoured: [String] = []
        var altered: [String: String] = [:]

        for candidate in candidates {
            try await withServer({ _ in .json("{}") }) { server in
                let plan = SendPlan(
                    method: .post,
                    url: try requireURL(server.baseURL),
                    headers: [.init(name: candidate.name, value: candidate.value)],
                    body: .bytes(Data("probe".utf8))
                )
                _ = await run(plan, server: server)

                let seen = server.received.first?.headers[candidate.name.lowercased()]
                if seen == candidate.value {
                    honoured.append(candidate.name)
                } else {
                    altered[candidate.name] = seen ?? "<absent>"
                }
            }
        }

        print(
            "--- URLSession header fidelity on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ---"
        )
        print("honoured verbatim: \(honoured.sorted().joined(separator: ", "))")
        for (name, actual) in altered.sorted(by: { $0.key < $1.key }) {
            print("  altered  \(name): sent \"\(actual)\"")
        }

        // An ordinary header must always survive; if this breaks, something is deeply wrong.
        #expect(honoured.contains("X-Ordinary"))

        // Whatever the probe found must match what we warn users about up front. This is the
        // assertion that actually matters: the two must not drift.
        let observedReserved = Set(altered.keys.map { $0.lowercased() })
        #expect(
            observedReserved == HTTPEngine.reservedHeaderFields,
            """
            Reserved-header set drifted from observed behaviour.
              observed: \(observedReserved.sorted())
              declared: \(HTTPEngine.reservedHeaderFields.sorted())
            Update HTTPEngine.reservedHeaderFields and docs/http-fidelity.md.
            """
        )
    }

    @Test("repeated header fields are combined into one line")
    func duplicateHeadersAreJoined() async throws {
        try await withServer({ _ in .json("{}") }) { server in
            let plan = SendPlan(
                method: .get,
                url: try requireURL(server.baseURL),
                headers: [
                    .init(name: "X-Trial", value: "one"),
                    .init(name: "X-Trial", value: "two"),
                ]
            )
            _ = await run(plan, server: server)

            let received = try #require(server.received.first)
            // URLSession cannot emit two lines with the same field name. It comma-joins them,
            // which is semantically equivalent for most headers but NOT for Set-Cookie-style ones.
            let trialLines = received.rawHeaderLines.filter {
                $0.lowercased().hasPrefix("x-trial:")
            }
            #expect(trialLines.count == 1)
            #expect(
                received.headers["x-trial"] == "one,two"
                    || received.headers["x-trial"] == "one, two")
        }
    }

    @Test("reservedHeaders warns before sending, not just after")
    func reservedHeaderPreflight() {
        let flagged = HTTPEngine.reservedHeaders(in: [
            .init(name: "content-length", value: "5"),
            .init(name: "Transfer-Encoding", value: "chunked"),
            // Honoured verbatim on macOS 26, so it must NOT be flagged -- warning about a header
            // that works would train users to ignore the warnings.
            .init(name: "Host", value: "vhost.example"),
            .init(name: "Authorization", value: "Bearer x"),
            .init(name: "X-Fine", value: "yes"),
        ])
        #expect(Set(flagged) == ["content-length", "Transfer-Encoding"])
    }

    // MARK: - Redirects

    @Test("each redirect hop is reported")
    func redirectHopsReported() async throws {
        try await withServer({ request in
            switch request.path {
            case "/one": .redirect(to: "/two")
            case "/two": .redirect(to: "/three")
            default: .json(#"{"done":true}"#)
            }
        }) { server in
            let plan = SendPlan(
                method: .get, url: try requireURL("\(server.baseURL)/one"))
            let events = await run(plan, server: server)

            let result = try #require(self.result(events))
            #expect(result.head.status == 200)
            #expect(result.hops.count == 2)
            #expect(result.hops.first?.status == 302)
        }
    }

    @Test("redirects can be turned off, delivering the 3xx itself")
    func redirectsOff() async throws {
        try await withServer({ request in
            request.path == "/start" ? .redirect(to: "/end") : .json("{}")
        }) { server in
            let plan = SendPlan(
                method: .get,
                url: try requireURL("\(server.baseURL)/start"),
                redirects: .none
            )
            let events = await run(plan, server: server)
            #expect(self.result(events)?.head.status == 302)
        }
    }

    @Test("the redirect limit is enforced")
    func redirectLimit() async throws {
        try await withServer({ _ in .redirect(to: "/loop") }) { server in
            let plan = SendPlan(
                method: .get,
                url: try requireURL("\(server.baseURL)/loop"),
                redirects: SendPlan.RedirectPolicy(follow: true, maximum: 3)
            )
            let events = await run(plan, server: server)
            // Either our limit fires or URLSession's does; both must terminate, and neither may
            // hang or silently succeed.
            let failure = try #require(self.failure(events))
            #expect(
                failure.kind == .tooManyRedirects
                    || failure.message.lowercased().contains("redirect"))
        }
    }

    /// The deviation most likely to surprise someone migrating from curl.
    @Test("a POST becomes a GET across a 302 unless we preserve the method")
    func methodRewrittenOnRedirect() async throws {
        try await withServer({ request in
            request.path == "/start" ? .redirect(to: "/end", status: 302) : .json("{}")
        }) { server in
            let base = server.baseURL

            let defaultPlan = SendPlan(
                method: .post,
                url: try requireURL("\(base)/start"),
                body: .bytes(Data("x=1".utf8))
            )
            _ = await run(defaultPlan, server: server)
            let afterDefault = server.received.last?.method

            let preservingPlan = SendPlan(
                method: .post,
                url: try requireURL("\(base)/start"),
                body: .bytes(Data("x=1".utf8)),
                redirects: SendPlan.RedirectPolicy(follow: true, preserveMethod: true)
            )
            _ = await run(preservingPlan, server: server)
            let afterPreserving = server.received.last?.method

            #expect(afterDefault == "GET", "URLSession rewrites POST to GET on 302")
            #expect(afterPreserving == "POST", "preserveMethod should re-apply the original verb")
        }
    }

    // MARK: - Bodies and failures

    @Test("a large response spills to a file instead of staying in memory")
    func largeResponseSpills() async throws {
        // Just over the 8 MB threshold.
        let payload = Data(repeating: UInt8(ascii: "a"), count: Int(bodyMemoryLimit) + 1024)
        try await withServer({ _ in
            TestHTTPServer.Response(
                status: 200, headers: ["Content-Type": "text/plain"], body: payload)
        }) { server in
            let plan = SendPlan(
                method: .get, url: try requireURL(server.baseURL))
            let events = await run(plan, server: server)

            let result = try #require(self.result(events))
            guard case .file(let url, let count) = result.payload else {
                Issue.record("expected a spilled file payload, got \(result.payload)")
                return
            }
            #expect(count == Int64(payload.count))
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("progress is reported while the body downloads")
    func progressReported() async throws {
        let payload = Data(repeating: UInt8(ascii: "b"), count: 512 * 1024)
        try await withServer({ _ in
            TestHTTPServer.Response(
                status: 200, headers: ["Content-Type": "text/plain"], body: payload)
        }) { server in
            let plan = SendPlan(
                method: .get, url: try requireURL(server.baseURL))
            let events = await run(plan, server: server)

            let chunks = events.compactMap { event -> Int64? in
                if case .bodyChunk(let received, _) = event { return received }
                return nil
            }
            #expect(!chunks.isEmpty)
            #expect(chunks == chunks.sorted(), "reported byte counts must be monotonic")
        }
    }

    @Test("connecting to a dead port fails with an actionable message, not a raw code")
    func deadPortFails() async throws {
        // Port 1 is reserved and nothing listens there.
        let plan = SendPlan(method: .get, url: try requireURL("http://127.0.0.1:1/"))
        let engine = HTTPEngine()
        var events: [SendEvent] = []
        for await event in engine.send(plan) { events.append(event) }

        let failure = try #require(self.failure(events))
        #expect(failure.kind == .cannotConnect)
        #expect(failure.message.contains("reachable"))
    }

    @Test("timing breaks down into phases")
    func timingPhases() async throws {
        try await withServer({ _ in .json("{}") }) { server in
            let plan = SendPlan(
                method: .get, url: try requireURL(server.baseURL))
            let events = await run(plan, server: server)

            let timing = try #require(self.result(events)?.timing)
            #expect(timing.total > .zero)
            // Loopback has no DNS and no TLS, so those are legitimately nil -- the point is that
            // the fields are populated from real metrics rather than invented.
            #expect(timing.timeToFirstByte != nil || timing.request != nil)
        }
    }
}
