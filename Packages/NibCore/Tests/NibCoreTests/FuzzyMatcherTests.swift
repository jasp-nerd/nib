import Foundation
import Testing

@testable import NibCore

/// Ranking is a judgement call, so these tests pin the *relative* order that makes the switcher feel
/// right rather than absolute scores, which would break on any tuning.
@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    private func candidates(_ names: [String]) -> [FuzzyMatcher.Candidate] {
        names.enumerated().map {
            FuzzyMatcher.Candidate(id: NodeID(rawValue: "id\($0.offset)"), text: $0.element)
        }
    }

    private func ranked(_ query: String, _ names: [String]) -> [String] {
        FuzzyMatcher.match(query: query, in: candidates(names)).map(\.text)
    }

    // MARK: - Subsequence semantics

    @Test("matches a subsequence, not just a prefix")
    func subsequence() {
        #expect(ranked("lu", ["List users"]) == ["List users"])
        #expect(ranked("lstu", ["List users"]) == ["List users"])
    }

    @Test("a query with a character not present matches nothing")
    func rejectsMissingCharacters() {
        #expect(ranked("xyz", ["List users", "Create user"]).isEmpty)
    }

    @Test("order matters: the same letters in the wrong order do not match")
    func orderMatters() {
        #expect(ranked("ul", ["Users"]).isEmpty)
    }

    @Test("an empty query returns everything in its original order")
    func emptyQueryBrowses() {
        #expect(ranked("", ["Zebra", "Apple"]) == ["Zebra", "Apple"])
    }

    @Test("matching is case-insensitive and ignores spaces in the query")
    func caseAndSpaces() {
        #expect(ranked("LU", ["List users"]) == ["List users"])
        #expect(ranked("l u", ["List users"]) == ["List users"])
    }

    // MARK: - Ranking
    //
    // These are the behaviours that make the switcher feel right.

    @Test("word-start matches rank above mid-word ones")
    func prefersWordStarts() {
        let result = ranked("lu", ["Casually", "List users"])
        #expect(result.first == "List users")
    }

    @Test("consecutive matches rank above scattered ones")
    func prefersConsecutive() {
        let result = ranked("user", ["Update series", "Users"])
        #expect(result.first == "Users")
    }

    @Test("an exact short name beats a longer one containing the same letters")
    func prefersShorter() {
        let result = ranked("user", ["Users", "Update user session records"])
        #expect(result.first == "Users")
    }

    @Test("a prefix match ranks first")
    func prefersPrefix() {
        let result = ranked("cre", ["Recreate index", "Create user"])
        #expect(result.first == "Create user")
    }

    // MARK: - Highlighting

    @Test("reports the offsets that matched, for highlighting")
    func reportsOffsets() throws {
        let matches = FuzzyMatcher.match(query: "lu", in: candidates(["List users"]))
        let match = try #require(matches.first)
        #expect(match.matchedOffsets.count == 2)
        // "List users" -- 'l' at 0, 'u' at 5.
        #expect(match.matchedOffsets == [0, 5])
    }

    // MARK: - Limits

    @Test("results are capped")
    func respectsLimit() {
        let many = candidates((0..<500).map { "Request \($0)" })
        #expect(FuzzyMatcher.match(query: "req", in: many, limit: 10).count == 10)
    }

    // MARK: - Folder paths

    @Test("the folder path is searchable, so a folder name narrows the results")
    func searchesFolderPath() {
        let collection = NibCore.Collection(
            name: "C",
            children: [
                .folder(
                    FolderNode(
                        name: "Auth",
                        children: [
                            .request(
                                RequestNode(name: "Login", spec: HTTPRequestSpec(url: "https://a")))
                        ])),
                .folder(
                    FolderNode(
                        name: "Users",
                        children: [
                            .request(
                                RequestNode(name: "Login", spec: HTTPRequestSpec(url: "https://b")))
                        ])),
            ])

        let all = collection.fuzzyCandidates()
        #expect(all.count == 2)
        #expect(all.map(\.text).contains("Auth / Login"))

        // Two identically-named requests are told apart by their folder.
        let matches = FuzzyMatcher.match(query: "authlog", in: all)
        #expect(matches.count == 1)
        #expect(matches.first?.text == "Auth / Login")
    }

    // MARK: - Performance

    /// The budget is 16 ms per keystroke to hold 60 fps, and it applies to a **release** build.
    ///
    /// Asserting it in debug measures the wrong thing: bounds checking, retain/release traffic and
    /// no inlining put the same work at ~18 ms there versus well under 1 ms optimised. An earlier
    /// version of this test asserted 16 ms unconditionally and failed in debug for a function that is
    /// comfortably fast in the build users actually run -- which would have led to optimising against
    /// a phantom.
    ///
    /// So: the real budget is enforced in release, and debug gets a loose ceiling that still catches
    /// an algorithmic regression (an accidental O(n^2), a lost rejection pass) without failing on
    /// constant-factor noise.
    @Test("ranking 5,000 candidates stays inside the frame budget")
    func performance() {
        let many = candidates((0..<5000).map { "Folder \($0 % 50) / Request number \($0)" })

        let start = ContinuousClock.now
        _ = FuzzyMatcher.match(query: "req42", in: many)
        let elapsed = ContinuousClock.now - start

        let milliseconds =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        #if DEBUG
        let budget = 120.0
        #else
        let budget = 16.0
        #endif

        #expect(milliseconds < budget, "took \(milliseconds) ms, budget \(budget) ms")
    }
}
