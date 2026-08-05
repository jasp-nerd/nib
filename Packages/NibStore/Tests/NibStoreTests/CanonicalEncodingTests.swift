import Foundation
import Testing

@testable import NibStore

/// The on-disk format is only "git-friendly" if writing the same model twice produces the
/// same bytes twice. If it does not, every save churns the diff, `git status` is never clean,
/// and the second-biggest pitch of the product quietly stops being true.
///
/// So this is a hard invariant with a test, not a hopeful property of JSONEncoder.
@Suite("Canonical encoding")
struct CanonicalEncodingTests {

    /// Shaped like a real request file: mixed key ordering, a URL with slashes, a nested
    /// object, an array, and an optional that is nil.
    private struct Fixture: Codable, Sendable {
        var url: String
        var method: String
        var headers: [Header]
        var settings: Settings
        var description: String?

        struct Header: Codable, Sendable {
            var name: String
            var value: String
            var enabled: Bool
        }

        struct Settings: Codable, Sendable {
            var timeoutMs: Int
            var followRedirects: Bool
            var verifyTLS: Bool
        }

        static let sample = Fixture(
            url: "{{baseUrl}}/orgs/:orgId/users?notify=true",
            method: "POST",
            headers: [
                .init(name: "Content-Type", value: "application/json", enabled: true),
                .init(name: "Accept", value: "application/json", enabled: true),
                .init(name: "X-Debug", value: "1", enabled: false),
            ],
            settings: .init(timeoutMs: 30000, followRedirects: true, verifyTLS: true),
            description: nil
        )
    }

    @Test("encoding the same model 1000 times yields exactly one byte sequence")
    func deterministic() throws {
        var outputs = Set<Data>()
        for _ in 0..<1000 {
            outputs.insert(try StoreLocations.encodeForDisk(Fixture.sample))
        }
        #expect(outputs.count == 1)
    }

    @Test("keys are sorted, so dictionary iteration order cannot leak into the file")
    func sortedKeys() throws {
        let text = try #require(
            String(data: try StoreLocations.encodeForDisk(Fixture.sample), encoding: .utf8)
        )

        // Top-level keys must appear alphabetically regardless of declaration order.
        let headersAt = try #require(text.range(of: "\"headers\""))
        let methodAt = try #require(text.range(of: "\"method\""))
        let settingsAt = try #require(text.range(of: "\"settings\""))
        let urlAt = try #require(text.range(of: "\"url\""))

        #expect(headersAt.lowerBound < methodAt.lowerBound)
        #expect(methodAt.lowerBound < settingsAt.lowerBound)
        #expect(settingsAt.lowerBound < urlAt.lowerBound)
    }

    @Test("slashes are not escaped, so URLs stay readable in a diff")
    func unescapedSlashes() throws {
        let text = try #require(
            String(data: try StoreLocations.encodeForDisk(Fixture.sample), encoding: .utf8)
        )
        #expect(text.contains("{{baseUrl}}/orgs/:orgId/users"))
        #expect(!text.contains("\\/"))
    }

    @Test("output is pretty-printed and ends in exactly one newline")
    func trailingNewline() throws {
        let data = try StoreLocations.encodeForDisk(Fixture.sample)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.hasSuffix("}\n"))
        #expect(!text.hasSuffix("\n\n"))
        // Pretty-printed means one field per line, so a one-field change is a one-line diff.
        #expect(text.contains("\n"))
        #expect(text.components(separatedBy: "\n").count > 5)
    }

    @Test("re-encoding a decoded file round-trips to identical bytes")
    func roundTripStable() throws {
        let first = try StoreLocations.encodeForDisk(Fixture.sample)
        let decoded = try JSONDecoder().decode(Fixture.self, from: first)
        let second = try StoreLocations.encodeForDisk(decoded)
        #expect(first == second)
    }
}

@Suite("Store layout")
struct StoreLayoutTests {
    @Test("bodies are sibling files, never inlined")
    func bodyIsSibling() {
        #expect(
            StoreLocations.bodyFilename(forRequestNamed: "Create user")
                == "Create user.req.body.json"
        )
    }

    /// Guards the two-store split. History must never resolve inside a user's collection
    /// folder — that would commit response bodies into their git repo.
    @Test("history lives under Application Support, not in the collection folder")
    func historyIsPrivate() throws {
        let history = try StoreLocations.historyDirectory().path
        #expect(history.contains("Application Support"))
        #expect(history.contains("/Nib/"))
    }
}
