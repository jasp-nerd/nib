import Foundation
import Testing

@testable import NibInterchange

/// Phase 4 drives the Postman importer off a corpus of real collections, so the plumbing that
/// loads that corpus is verified now rather than discovered to be broken later.
@Suite("Fixture corpus")
struct FixtureCorpusTests {

    static func fixturesRoot() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    @Test("the corpus directory is bundled and reachable")
    func corpusIsBundled() throws {
        let root = try Self.fixturesRoot()
        #expect(FileManager.default.fileExists(atPath: root.path))

        // `expected/` was planned for ImportResult snapshots and never written; the importer
        // tests assert inline instead. It was in this list as an empty directory, which git does
        // not track — so it existed on the machine that wrote the test and nowhere else, and CI
        // failed on a fresh checkout. Asserting a directory with no contents and no readers was
        // testing nothing.
        for subdirectory in ["postman", "curl"] {
            let path = root.appendingPathComponent(subdirectory)
            #expect(
                FileManager.default.fileExists(atPath: path.path),
                "missing fixture subdirectory: \(subdirectory)"
            )
        }
    }

    /// Reminder, not a failure. The corpus is populated in Phase 4; until then this prints a
    /// count so it is obvious the suite is not yet meaningful.
    @Test("reports how many Postman fixtures are present")
    func corpusSize() throws {
        let postman = try Self.fixturesRoot().appendingPathComponent("postman")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: postman.path)) ?? []
        let collections = files.filter { $0.hasSuffix(".json") }
        // Not an assertion on count -- the corpus is populated in Phase 4. Printing it keeps it
        // visible that this suite is not yet meaningful, without a green check that implies it is.
        Comment.hint("Postman fixtures present: \(collections.count) (target for Phase 4: 30+)")
        #expect(files.allSatisfy { !$0.hasPrefix(".") } || files.isEmpty)
    }
}

extension Comment {
    /// Small helper so progress notes read consistently in test output.
    static func hint(_ message: String) {
        print("[fixtures] \(message)")
    }
}
