import Foundation

// The tokenizers, one per dialect, each decomposed into a scanner per quoting style.
//
// Splitting it this way is not just to satisfy a complexity limit: a tokenizer written as one long
// switch is where off-by-one index bugs hide, and each scanner below has exactly one job with one
// clear postcondition (it returns the text and the index just past the closing quote).

extension ShellLexer {

    /// Accumulates characters into words, tracking whether a word has started.
    ///
    /// The `hasCurrent` flag exists because `''` is a real, empty argument — distinct from no
    /// argument at all. Tracking emptiness with `current.isEmpty` would silently drop it.
    private struct WordAccumulator {
        private(set) var tokens: [String] = []
        private var current = ""
        private var hasCurrent = false

        mutating func append(_ character: Character) {
            current.append(character)
            hasCurrent = true
        }

        mutating func append(_ text: String) {
            current += text
            hasCurrent = true
        }

        /// Mark a word as started without adding anything, for an empty quoted string.
        mutating func beginWord() {
            hasCurrent = true
        }

        mutating func flush() {
            guard hasCurrent else { return }
            tokens.append(current)
            current = ""
            hasCurrent = false
        }

        mutating func finish() -> [String] {
            flush()
            return tokens
        }
    }

    /// Whitespace that separates words.
    ///
    /// Uses `Character.isWhitespace` rather than comparing against `" "`, `"\t"`, `"\n"`, `"\r"`.
    /// Swift treats **`"\r\n"` as a single `Character`** — one grapheme cluster — so the explicit
    /// comparison silently fails on Windows line endings, which is exactly what devtools on Windows
    /// produces.
    private static func isWhitespace(_ character: Character) -> Bool {
        character.isWhitespace
    }

    // MARK: - POSIX

    static func tokenizePOSIX(_ input: String) throws -> [String] {
        var words = WordAccumulator()
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]

            if isWhitespace(character) {
                words.flush()
                index = input.index(after: index)
                continue
            }

            switch character {
            case "\\":
                index = consumeBackslash(input, at: index, into: &words)

            case "'":
                words.beginWord()
                let (text, next) = try scanSingleQuoted(input, from: input.index(after: index))
                words.append(text)
                index = next

            case "\"":
                words.beginWord()
                let (text, next) = try scanDoubleQuoted(input, from: input.index(after: index))
                words.append(text)
                index = next

            case "$":
                // ANSI-C quoting: $'a\nb'. Chrome emits this when a value contains an escape.
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == "'" {
                    words.beginWord()
                    let (text, after) = try scanANSICQuoted(input, from: input.index(after: next))
                    words.append(text)
                    index = after
                } else {
                    words.append(character)
                    index = next
                }

            default:
                words.append(character)
                index = input.index(after: index)
            }
        }

        return words.finish()
    }

    /// A backslash outside quotes: escapes the next character, or continues the line.
    private static func consumeBackslash(
        _ input: String,
        at index: String.Index,
        into words: inout WordAccumulator
    ) -> String.Index {
        let next = input.index(after: index)
        guard next < input.endIndex else { return next }

        // Backslash-newline is a line continuation: both vanish.
        //
        // `isNewline` rather than `== "\n" || == "\r"`, because Swift treats `"\r\n"` as one
        // `Character`. Comparing against the individual scalars misses CRLF entirely, so a command
        // copied from Windows devtools kept a literal backslash in the middle of a token.
        guard input[next].isNewline else {
            words.append(input[next])
            return input.index(after: next)
        }

        // One index step is enough even for CRLF: it is a single Character.
        return input.index(after: next)
    }

    /// Single quotes are fully literal: no escapes of any kind inside them.
    private static func scanSingleQuoted(
        _ input: String,
        from start: String.Index
    ) throws -> (String, String.Index) {
        var text = ""
        var index = start

        while index < input.endIndex {
            if input[index] == "'" {
                return (text, input.index(after: index))
            }
            text.append(input[index])
            index = input.index(after: index)
        }

        throw LexError.unterminatedQuote("'")
    }

    /// Inside double quotes a backslash escapes only a few characters; otherwise it stays literal,
    /// so a Windows path like `"C:\Users"` survives intact.
    private static func scanDoubleQuoted(
        _ input: String,
        from start: String.Index
    ) throws -> (String, String.Index) {
        let escapable: Set<Character> = ["\"", "\\", "$", "`", "\n"]
        var text = ""
        var index = start

        while index < input.endIndex {
            let character = input[index]

            if character == "\"" {
                return (text, input.index(after: index))
            }

            guard character == "\\" else {
                text.append(character)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else { break }

            if escapable.contains(input[next]) {
                // An escaped newline disappears entirely.
                if input[next] != "\n" { text.append(input[next]) }
            } else {
                text.append(character)
                text.append(input[next])
            }
            index = input.index(after: next)
        }

        throw LexError.unterminatedQuote("\"")
    }

    /// `$'…'` — ANSI-C quoting, where the usual C escapes apply.
    private static func scanANSICQuoted(
        _ input: String,
        from start: String.Index
    ) throws -> (String, String.Index) {
        var text = ""
        var index = start

        while index < input.endIndex {
            let character = input[index]

            if character == "'" {
                return (text, input.index(after: index))
            }

            guard character == "\\" else {
                text.append(character)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else { break }

            if let (scalar, after) = numericEscape(input, at: next) {
                text.append(scalar)
                index = after
                continue
            }

            text.append(simpleEscape(input[next]))
            index = input.index(after: next)
        }

        throw LexError.unterminatedQuote("'")
    }

    private static func simpleEscape(_ character: Character) -> Character {
        switch character {
        case "n": "\n"
        case "t": "\t"
        case "r": "\r"
        case "a": "\u{07}"
        case "b": "\u{08}"
        case "f": "\u{0C}"
        case "v": "\u{0B}"
        case "e": "\u{1B}"
        case "0": "\0"
        // Anything else -- including `\\`, `\'` and `\"` -- is itself.
        default: character
        }
    }

    /// `\xNN` and `\uNNNN`.
    private static func numericEscape(
        _ input: String,
        at index: String.Index
    ) -> (Character, String.Index)? {
        let maximumDigits: Int
        switch input[index] {
        case "x": maximumDigits = 2
        case "u": maximumDigits = 4
        default: return nil
        }

        var digits = ""
        var cursor = input.index(after: index)
        while cursor < input.endIndex, digits.count < maximumDigits, input[cursor].isHexDigit {
            digits.append(input[cursor])
            cursor = input.index(after: cursor)
        }

        guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else {
            return nil
        }
        return (Character(scalar), cursor)
    }

    // MARK: - Windows cmd

    /// The `cmd.exe` dialect that Chrome's "Copy as cURL (cmd)" produces.
    ///
    /// The cmd-specific escapes are normalised first, after which the quoting rules are close enough
    /// to POSIX double-quoting to need only one scanner.
    static func tokenizeWindowsCmd(_ input: String) throws -> [String] {
        var normalized = input.replacingOccurrences(of: "^%^", with: "%")
        normalized = normalized.replacingOccurrences(of: "^\r\n", with: "")
        normalized = normalized.replacingOccurrences(of: "^\n", with: "")
        normalized = normalized.replacingOccurrences(of: "^\"", with: "\"")

        var words = WordAccumulator()
        var index = normalized.startIndex

        while index < normalized.endIndex {
            let character = normalized[index]

            if isWhitespace(character) {
                words.flush()
                index = normalized.index(after: index)
                continue
            }

            if character == "\"" {
                words.beginWord()
                let (text, next) = try scanWindowsQuoted(
                    normalized, from: normalized.index(after: index))
                words.append(text)
                index = next
                continue
            }

            words.append(character)
            index = normalized.index(after: index)
        }

        return words.finish()
    }

    /// In cmd, both `\"` and `""` mean a literal quote inside a quoted string.
    private static func scanWindowsQuoted(
        _ input: String,
        from start: String.Index
    ) throws -> (String, String.Index) {
        var text = ""
        var index = start

        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)

            if character == "\\", next < input.endIndex, input[next] == "\"" {
                text.append("\"")
                index = input.index(after: next)
                continue
            }

            if character == "\"" {
                if next < input.endIndex, input[next] == "\"" {
                    text.append("\"")
                    index = input.index(after: next)
                    continue
                }
                return (text, next)
            }

            text.append(character)
            index = next
        }

        throw LexError.unterminatedQuote("\"")
    }
}
