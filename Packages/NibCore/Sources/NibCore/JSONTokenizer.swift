import Foundation

/// Syntax colouring for JSON, one line at a time.
///
/// **The insight this whole file rests on: a JSON token can never span a line.** String literals
/// forbid raw newlines, there are no block comments, and there is no multi-line construct of any
/// kind. So tokenization is *stateless at line granularity* — line 40,000 can be coloured correctly
/// without having read lines 1 to 39,999.
///
/// That single property is what makes highlighting cheap enough to do without a dependency. The
/// viewport highlighter asks for tokens on the twenty or so lines actually on screen, and cost stays
/// proportional to the window rather than to the response. Highlightr would have embedded
/// highlight.js *and* a JavaScript runtime, roughly doubling the app, to do a strictly worse job.
///
/// ## Offsets are UTF-16 code units
///
/// Not bytes, and not `String.Index`. The only consumer is TextKit, where a range is an `NSRange`
/// and `NSRange` counts UTF-16 code units. Returning byte offsets would mean a conversion per token
/// on every frame of scrolling, and returning `String.Index` would mean the tokenizer could not be
/// tested without a `String` to index into. Every character JSON gives syntactic meaning to is
/// ASCII, so scanning code units costs nothing and non-ASCII inside a string literal is stepped over
/// without being looked at.
///
/// ## Tolerant, never strict
///
/// This colours text while it is being typed and while it is half-received. It is not a validator:
/// it never throws, never rejects, and never hangs. Anything it does not understand simply produces
/// no token and stays the default colour.
public enum JSONTokenizer {

    public enum Kind: Sendable, Hashable, CaseIterable {
        /// A string used as an object key — a string whose next non-space neighbour is `:`.
        case key
        case string
        case number
        /// `true`, `false`, `null`.
        case literal
        case punctuation
    }

    /// A coloured span, in UTF-16 code units from the start of the line.
    public struct Token: Sendable, Hashable {
        public let kind: Kind
        public let start: Int
        public let length: Int

        public init(kind: Kind, start: Int, length: Int) {
            self.kind = kind
            self.start = start
            self.length = length
        }

        public var end: Int { start + length }
    }

    /// Tokenize one line. The line must not contain a newline; if it does, it is treated as
    /// ordinary content, which is the tolerant thing to do rather than an assertion.
    public static func tokens(inLine line: String) -> [Token] {
        tokens(inLine: Array(line.utf16))
    }

    /// The real entry point. Taking the code units directly lets a caller that already has them —
    /// the viewport highlighter walking a paragraph at a time — avoid re-encoding per frame.
    public static func tokens(inLine units: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        var index = 0

        while index < units.count {
            let unit = units[index]

            switch unit {
            case Ascii.quote:
                let token = scanString(units, from: index)
                // A key is just a string that turns out to be followed by a colon. Decidable on
                // this line alone, which is the whole point of the no-token-spans-a-line property.
                let isKey = nextMeaningfulUnit(units, after: token.end) == Ascii.colon
                tokens.append(
                    Token(kind: isKey ? .key : .string, start: token.start, length: token.length))
                index = token.end

            case Ascii.leftBrace, Ascii.rightBrace, Ascii.leftBracket, Ascii.rightBracket,
                Ascii.comma, Ascii.colon:
                tokens.append(Token(kind: .punctuation, start: index, length: 1))
                index += 1

            case Ascii.minus, Ascii.zero...Ascii.nine:
                let end = scanNumber(units, from: index)
                tokens.append(Token(kind: .number, start: index, length: end - index))
                index = end

            case Ascii.t, Ascii.f, Ascii.n:
                if let end = scanLiteral(units, from: index) {
                    tokens.append(Token(kind: .literal, start: index, length: end - index))
                    index = end
                } else {
                    index = skipWord(units, from: index)
                }

            default:
                index += 1
            }
        }

        return tokens
    }

    // MARK: - Scanners

    /// From an opening quote to just past the closing one.
    ///
    /// An unterminated string runs to the end of the line rather than being discarded. Half a string
    /// is what you have while you are still typing it, and colouring it as a string is both more
    /// useful and less distracting than leaving it plain until the moment you close the quote.
    private static func scanString(_ units: [UInt16], from start: Int) -> Token {
        var index = start + 1
        while index < units.count {
            let unit = units[index]
            if unit == Ascii.backslash {
                // Skip the escaped unit, whatever it is. A trailing backslash at end of line just
                // ends the loop, which is correct: there is nothing after it to escape.
                index += 2
                continue
            }
            if unit == Ascii.quote {
                return Token(kind: .string, start: start, length: index + 1 - start)
            }
            index += 1
        }
        return Token(kind: .string, start: start, length: units.count - start)
    }

    /// A run of number-shaped units.
    ///
    /// Deliberately looser than the JSON grammar: `1.2.3` and `1e` colour as one number rather than
    /// as a number plus debris. Being right about where the number *ends* is what matters here;
    /// being right about whether it is well-formed is the parser's job, and the parse failure is
    /// already reported elsewhere.
    private static func scanNumber(_ units: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < units.count {
            switch units[index] {
            case Ascii.zero...Ascii.nine, Ascii.dot, Ascii.e, Ascii.upperE, Ascii.plus, Ascii.minus:
                index += 1
            default:
                return index
            }
        }
        return index
    }

    private static let literals: [[UInt16]] = [
        Array("true".utf16), Array("false".utf16), Array("null".utf16),
    ]

    /// Matches only a whole word, so `nullish` is not coloured as `null` followed by `ish`.
    private static func scanLiteral(_ units: [UInt16], from start: Int) -> Int? {
        for literal in literals {
            let end = start + literal.count
            guard end <= units.count else { continue }
            guard Array(units[start..<end]) == literal else { continue }
            guard end == units.count || !isWordUnit(units[end]) else { continue }
            return end
        }
        return nil
    }

    private static func skipWord(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index < units.count, isWordUnit(units[index]) {
            index += 1
        }
        // Always advance. A `while` loop whose body can leave the index unchanged is how a
        // highlighter becomes a hang.
        return max(index, start + 1)
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case Ascii.a...Ascii.z, Ascii.upperA...Ascii.upperZ,
            Ascii.zero...Ascii.nine, Ascii.underscore:
            true
        default:
            false
        }
    }

    private static func nextMeaningfulUnit(_ units: [UInt16], after index: Int) -> UInt16? {
        var cursor = index
        while cursor < units.count {
            let unit = units[cursor]
            if unit != Ascii.space && unit != Ascii.tab { return unit }
            cursor += 1
        }
        return nil
    }

    /// The handful of code units with syntactic meaning. Named rather than spelled as literals so
    /// the switches above read as JSON rather than as arithmetic.
    private enum Ascii {
        static let tab: UInt16 = 9
        static let space: UInt16 = 32
        static let quote: UInt16 = 34
        static let plus: UInt16 = 43
        static let comma: UInt16 = 44
        static let minus: UInt16 = 45
        static let dot: UInt16 = 46
        static let zero: UInt16 = 48
        static let nine: UInt16 = 57
        static let colon: UInt16 = 58
        static let upperA: UInt16 = 65
        static let upperE: UInt16 = 69
        static let upperZ: UInt16 = 90
        static let leftBracket: UInt16 = 91
        static let backslash: UInt16 = 92
        static let rightBracket: UInt16 = 93
        static let underscore: UInt16 = 95
        static let a: UInt16 = 97
        static let e: UInt16 = 101
        static let f: UInt16 = 102
        static let n: UInt16 = 110
        static let t: UInt16 = 116
        static let z: UInt16 = 122
        static let leftBrace: UInt16 = 123
        static let rightBrace: UInt16 = 125
    }
}
