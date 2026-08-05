import Foundation
import Testing

@testable import NibCore

@Suite("JSONTokenizer")
struct JSONTokenizerTests {

    /// Render a line as a kind-per-token summary, which is what the assertions below actually care
    /// about. Comparing `[Token]` literals would make every test unreadable.
    private func kinds(_ line: String) -> [JSONTokenizer.Kind] {
        JSONTokenizer.tokens(inLine: line).map(\.kind)
    }

    /// The text each token covers, so an off-by-one in a range fails loudly instead of quietly
    /// colouring the neighbouring character.
    private func spans(_ line: String) -> [String] {
        let units = Array(line.utf16)
        return JSONTokenizer.tokens(inLine: line).map { token in
            String(decoding: units[token.start..<token.end], as: UTF16.self)
        }
    }

    // MARK: - The basics

    @Test("a key/value pair distinguishes the key from the value")
    func keyVersusString() {
        #expect(kinds(#""name": "Ada""#) == [.key, .punctuation, .string])
        #expect(spans(#""name": "Ada""#) == [#""name""#, ":", #""Ada""#])
    }

    /// The only thing that makes a string a key is a colon after it, and whitespace in between is
    /// legal. Postman exports and hand-edited files both contain this.
    @Test(
        "a key is recognised across whitespace before the colon",
        arguments: [#""k" : 1"#, "\"k\"\t: 1", #""k":1"#]
    )
    func keySpacing(line: String) {
        #expect(kinds(line).first == .key)
    }

    @Test("a string that is not followed by a colon is a value, not a key")
    func stringInArray() {
        #expect(
            kinds(#"["a", "b"]"#) == [.punctuation, .string, .punctuation, .string, .punctuation])
    }

    @Test(
        "literals are recognised",
        arguments: ["true", "false", "null"]
    )
    func literals(text: String) {
        #expect(kinds(text) == [.literal])
        #expect(spans(text) == [text])
    }

    /// A whole-word match, or `nullish` would colour as `null` plus debris.
    @Test(
        "a word that merely starts with a literal is not one",
        arguments: ["nullish", "trueish", "falsey", "nul", "truthy"]
    )
    func partialLiterals(text: String) {
        #expect(kinds(text).isEmpty)
    }

    @Test(
        "numbers are recognised in the shapes JSON allows",
        arguments: ["0", "-1", "3.14", "1e10", "1E+10", "-2.5e-3", "1234567890"]
    )
    func numbers(text: String) {
        #expect(kinds(text) == [.number])
        #expect(spans(text) == [text])
    }

    @Test("a number stops at the punctuation after it")
    func numberBoundary() {
        #expect(kinds("[1,2]") == [.punctuation, .number, .punctuation, .number, .punctuation])
        #expect(spans("[1,2]") == ["[", "1", ",", "2", "]"])
    }

    // MARK: - Strings

    @Test("an escaped quote does not end the string")
    func escapedQuote() {
        let line = #""she said \"hi\"""#
        #expect(kinds(line) == [.string])
        #expect(spans(line) == [line])
    }

    @Test("an escaped backslash at the end of a string does not swallow the closing quote")
    func escapedBackslash() {
        // The value is a single backslash: "\\" -- if the escape handling is wrong, the closing
        // quote is consumed and the token runs to end of line.
        let line = #"{"path": "C:\\"}"#
        #expect(kinds(line) == [.punctuation, .key, .punctuation, .string, .punctuation])
        #expect(spans(line).last == "}")
    }

    /// Half a string is what exists while you are typing one, and while a chunked response is still
    /// arriving. Colouring it beats leaving it plain until the closing quote lands.
    @Test("an unterminated string runs to the end of the line rather than vanishing")
    func unterminatedString() {
        #expect(kinds(#""oops"#) == [.string])
        #expect(spans(#""oops"#) == [#""oops"#])
    }

    @Test("a trailing backslash at end of line terminates cleanly")
    func trailingBackslash() {
        #expect(kinds(#""oops\"#) == [.string])
    }

    // MARK: - Offsets are UTF-16 code units

    /// The offsets go straight into an `NSRange`, so they have to be in the same units TextKit
    /// counts in. Emoji are the case that catches a byte-based or character-based implementation:
    /// one grapheme, one Character, four UTF-8 bytes, two UTF-16 code units.
    @Test("offsets count UTF-16 code units, not bytes or characters")
    func utf16Offsets() throws {
        let line = #"{"k": "🎉", "n": 1}"#

        // Every token must slice cleanly out of the UTF-16 view at its own offsets.
        #expect(spans(line) == ["{", #""k""#, ":", #""🎉""#, ",", #""n""#, ":", "1", "}"])

        // And the last token must land inside the buffer TextKit will hand us.
        let last = try #require(JSONTokenizer.tokens(inLine: line).last)
        #expect(last.end == line.utf16.count)
    }

    @Test("non-ASCII outside a string does not shift later offsets")
    func nonAsciiPassthrough() {
        #expect(spans(#"ü "k": 1"#) == [#""k""#, ":", "1"])
    }

    // MARK: - Tolerance
    //
    // This colours text mid-download and mid-edit. None of these may throw, hang, or produce a
    // token that points outside the line.

    @Test(
        "malformed input produces tokens inside the line and never hangs",
        arguments: [
            "", " ", "{", "}", "{{", "]]", ":", ",,,", "{\"a\"", "{\"a\":", "-", ".", "e",
            "1.2.3", "1e", "--5", #"{"a": }"#, #"\"#, "\u{0}", "🎉", "nullnull",
        ]
    )
    func malformed(line: String) {
        let tokens = JSONTokenizer.tokens(inLine: line)
        let limit = line.utf16.count
        for token in tokens {
            #expect(token.start >= 0)
            #expect(token.end <= limit)
            #expect(token.length > 0)
        }
    }

    @Test("tokens are ordered and never overlap")
    func nonOverlapping() {
        let line = #"{"a": [1, true, "b"], "c": null}"#
        var cursor = 0
        for token in JSONTokenizer.tokens(inLine: line) {
            #expect(token.start >= cursor)
            cursor = token.end
        }
    }

    // MARK: - Performance
    //
    // The budget that matters is per *viewport*, not per document: the highlighter only ever asks
    // about the lines on screen. 200 lines is a generous full-screen window.

    @Test("a viewport's worth of lines tokenizes well inside a frame")
    func viewportBudget() {
        let line = #"    "identifier": "value-with-some-length", "count": 12345, "ok": true,"#
        let clock = ContinuousClock()

        let elapsed = clock.measure {
            for _ in 0..<200 {
                _ = JSONTokenizer.tokens(inLine: line)
            }
        }

        // 16 ms is one 60 Hz frame. Debug builds are several times slower than release, so this is
        // a smoke test for accidental quadratic behaviour rather than a real performance figure.
        #expect(elapsed < .milliseconds(16))
    }

    /// One 4 MB line is what a minified response looks like before pretty-printing. The tokenizer
    /// must stay linear on it — the display path also hard-wraps, but that is a separate guard and
    /// this one must hold on its own.
    @Test("a very long line stays linear")
    func longLine() {
        let line = "[" + Array(repeating: "12345", count: 100_000).joined(separator: ",") + "]"
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = JSONTokenizer.tokens(inLine: line) }
        #expect(elapsed < .milliseconds(500))
    }
}
