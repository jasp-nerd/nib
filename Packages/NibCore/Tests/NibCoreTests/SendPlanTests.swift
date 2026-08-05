import Foundation
import Testing

@testable import NibCore

@Suite("SendPlan")
struct SendPlanTests {

    @Test("defaults are the safe, conventional ones")
    func defaults() throws {
        let plan = SendPlan(method: .get, url: try #require(URL(string: "https://example.com")))

        #expect(plan.redirects.follow)
        #expect(plan.redirects.maximum == 10)
        #expect(plan.tls.verify)
        #expect(plan.timeout == .seconds(30))
        #expect(plan.body == .none)
    }

    /// `preserveMethod` defaults to off because that is what URLSession and browsers do.
    /// Turning it on is an explicit choice, made when a user typed `-X POST --location` and
    /// means it.
    @Test("method preservation across redirects is opt-in")
    func methodPreservationIsOptIn() {
        #expect(!SendPlan.RedirectPolicy.default.preserveMethod)
        #expect(SendPlan.RedirectPolicy(preserveMethod: true).preserveMethod)
    }

    /// TLS verification is never disabled by default and never disabled implicitly after a
    /// failure — the user has to ask, per request, having read what the error said.
    @Test("insecure TLS is never a default")
    func insecureIsExplicit() {
        #expect(SendPlan.TLSPolicy.default.verify)
        #expect(!SendPlan.TLSPolicy.insecure.verify)
    }

    /// Duplicate header names are kept as separate entries rather than collapsed. URLSession
    /// cannot actually emit two lines with the same name, but the model records what the user
    /// asked for so the engine can report the deviation instead of hiding it.
    @Test("duplicate header names are preserved in the model")
    func duplicateHeadersPreserved() throws {
        let plan = SendPlan(
            method: .get,
            url: try #require(URL(string: "https://example.com")),
            headers: [
                .init(name: "Accept", value: "application/json"),
                .init(name: "Accept", value: "text/plain"),
            ]
        )
        #expect(plan.headers.count == 2)
    }

    @Test("large bodies stream from a file rather than sitting in memory")
    func fileBodiesAreSupported() throws {
        let url = try #require(URL(string: "file:///tmp/upload.bin"))
        let plan = SendPlan(
            method: .post,
            url: try #require(URL(string: "https://example.com")),
            body: .file(url)
        )
        #expect(plan.body == .file(url))
        #expect(bodyMemoryLimit == 8 * 1024 * 1024)
    }

    @Test("custom verbs survive into the plan")
    func customVerb() throws {
        let plan = SendPlan(
            method: HTTPMethod("PROPFIND"),
            url: try #require(URL(string: "https://example.com"))
        )
        #expect(plan.method.rawValue == "PROPFIND")
    }
}
