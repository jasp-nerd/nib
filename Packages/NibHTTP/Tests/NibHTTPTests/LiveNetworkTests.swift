import Foundation
import NibCore
import Testing

@testable import NibHTTP

/// Tests that hit the real internet over HTTPS.
///
/// Gated behind `NIB_NETWORK_TESTS=1` because they need connectivity and are therefore not
/// deterministic enough for CI. Run them with:
///
///     NIB_NETWORK_TESTS=1 swift test --package-path Packages/NibHTTP --filter LiveNetwork
///
/// They exist because the localhost suite has a blind spot that cost real time: `TestHTTPServer`
/// speaks plain HTTP, so **no test ever triggered a TLS challenge**. Every request a user actually
/// makes is HTTPS, which means the entire server-trust path shipped unexercised.
@Suite(
    "LiveNetwork", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["NIB_NETWORK_TESTS"] == "1"))
struct LiveNetworkTests {

    private func run(_ plan: SendPlan) async -> [SendEvent] {
        let engine = HTTPEngine()
        var events: [SendEvent] = []
        for await event in engine.send(plan) { events.append(event) }
        return events
    }

    private func outcome(_ events: [SendEvent]) -> String {
        events.map { event in
            switch event {
            case .started: "started"
            case .redirected(let hop): "redirect(\(hop.status))"
            case .responseHead(let head): "head(\(head.status))"
            case .bodyChunk: "chunk"
            case .finished(let result): "finished(\(result.head.status))"
            case .failed(let failure): "FAILED(\(failure.kind): \(failure.message))"
            }
        }
        .joined(separator: " -> ")
    }

    @Test("a plain HTTPS GET against a well-known host succeeds")
    func httpsGet() async throws {
        let plan = SendPlan(
            method: .get, url: try #require(URL(string: "https://example.com")))
        let events = await run(plan)
        print("[live] example.com: \(outcome(events))")

        let finished = events.compactMap { event -> SendEvent.Result? in
            if case .finished(let result) = event { return result }
            return nil
        }.first
        let result = try #require(finished, "expected a response, got: \(outcome(events))")
        #expect(result.head.status == 200)
    }

    @Test("an HTTPS JSON API returns a body we can display")
    func httpsJSON() async throws {
        let plan = SendPlan(
            method: .get,
            url: try #require(URL(string: "https://api.github.com/repos/apple/swift")),
            headers: [.init(name: "Accept", value: "application/vnd.github+json")]
        )
        let events = await run(plan)
        print("[live] api.github.com: \(outcome(events))")

        let finished = events.compactMap { event -> SendEvent.Result? in
            if case .finished(let result) = event { return result }
            return nil
        }.first
        let result = try #require(finished, "expected a response, got: \(outcome(events))")
        #expect(result.head.status == 200)
        #expect(result.networkProtocol != nil)
    }

    @Test("a genuinely bad certificate fails with a TLS reason, not a generic error")
    func badCertificate() async throws {
        let plan = SendPlan(
            method: .get, url: try #require(URL(string: "https://expired.badssl.com")))
        let events = await run(plan)
        print("[live] expired.badssl.com: \(outcome(events))")

        let failure = events.compactMap { event -> SendEvent.Failure? in
            if case .failed(let failure) = event { return failure }
            return nil
        }.first
        let observed = try #require(failure, "expected a TLS failure, got: \(outcome(events))")
        guard case .tlsUntrusted = observed.kind else {
            Issue.record("expected .tlsUntrusted, got \(observed.kind)")
            return
        }
    }

    @Test("disabling verification lets a bad certificate through")
    func insecureOverride() async throws {
        let plan = SendPlan(
            method: .get,
            url: try #require(URL(string: "https://expired.badssl.com")),
            tls: .insecure
        )
        let events = await run(plan)
        print("[live] expired.badssl.com (insecure): \(outcome(events))")

        let finished = events.compactMap { event -> SendEvent.Result? in
            if case .finished(let result) = event { return result }
            return nil
        }.first
        #expect(finished != nil, "insecure override should succeed, got: \(outcome(events))")
    }
}
