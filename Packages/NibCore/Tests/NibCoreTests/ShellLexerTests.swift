import Testing

@testable import NibCore

/// Direct tests for the tokenizer.
///
/// The cURL import suite covers the three real devtools dialects end to end; this covers the edge
/// cases those fixtures happen not to contain. A tokenizer is where off-by-one index bugs live, and
/// they are much cheaper to find here than through a parsed request.
@Suite("ShellLexer")
struct ShellLexerTests {

    // MARK: - Words and whitespace

    @Test(
        "splits on whitespace",
        arguments: [
            ("curl https://x.example", ["curl", "https://x.example"]),
            ("  curl   https://x.example  ", ["curl", "https://x.example"]),
            ("curl\thttps://x.example", ["curl", "https://x.example"]),
            ("curl\nhttps://x.example", ["curl", "https://x.example"]),
            ("", []),
            ("   ", []),
        ]
    )
    func splitsWords(input: String, expected: [String]) throws {
        #expect(try ShellLexer.tokenize(input) == expected)
    }

    /// `''` is a real, empty argument — distinct from no argument. Tracking word-start with
    /// `isEmpty` instead of an explicit flag silently drops it.
    @Test("an empty quoted string is a real token")
    func emptyQuotedString() throws {
        #expect(try ShellLexer.tokenize("curl '' \"\"") == ["curl", "", ""])
    }

    @Test("quotes concatenate when adjacent, as a shell does")
    func adjacentQuotesConcatenate() throws {
        #expect(try ShellLexer.tokenize("'a'b'c'") == ["abc"])
        #expect(try ShellLexer.tokenize(#""a"'b'c"#) == ["abc"])
    }

    // MARK: - Single quotes

    @Test("single quotes are fully literal")
    func singleQuotesLiteral() throws {
        #expect(try ShellLexer.tokenize(#"'a\nb'"#) == [#"a\nb"#])
        #expect(try ShellLexer.tokenize(#"'a"b'"#) == [#"a"b"#])
        #expect(try ShellLexer.tokenize("'a b'") == ["a b"])
        #expect(try ShellLexer.tokenize(#"'a\b'"#) == [#"a\b"#])
    }

    // MARK: - Double quotes

    @Test("double quotes escape only a few characters")
    func doubleQuoteEscapes() throws {
        #expect(try ShellLexer.tokenize(#""a\"b""#) == [#"a"b"#])
        #expect(try ShellLexer.tokenize(#""a\\b""#) == [#"a\b"#])
        // A backslash before anything else stays literal, so Windows paths survive.
        #expect(try ShellLexer.tokenize(#""C:\Users\ada""#) == [#"C:\Users\ada"#])
    }

    @Test("a backslash-newline inside double quotes disappears")
    func doubleQuoteLineContinuation() throws {
        #expect(try ShellLexer.tokenize("\"a\\\nb\"") == ["ab"])
    }

    // MARK: - Line continuations

    @Test("backslash-newline outside quotes joins lines")
    func lineContinuation() throws {
        let input = """
            curl 'https://x.example' \\
              -H 'accept: application/json'
            """
        #expect(
            try ShellLexer.tokenize(input)
                == ["curl", "https://x.example", "-H", "accept: application/json"])
    }

    @Test("CRLF continuations work too")
    func crlfContinuation() throws {
        #expect(
            try ShellLexer.tokenize("curl \\\r\n  https://x.example")
                == ["curl", "https://x.example"])
    }

    // MARK: - ANSI-C quoting

    @Test(
        "ANSI-C escapes",
        arguments: [
            (#"$'a\nb'"#, "a\nb"),
            (#"$'a\tb'"#, "a\tb"),
            (#"$'a\rb'"#, "a\rb"),
            (#"$'a\\b'"#, #"a\b"#),
            (#"$'it\'s'"#, "it's"),
            (#"$'\x41'"#, "A"),
            (#"$'\u0041'"#, "A"),
            (#"$'plain'"#, "plain"),
        ]
    )
    func ansiCEscapes(input: String, expected: String) throws {
        #expect(try ShellLexer.tokenize(input) == [expected])
    }

    @Test("a bare dollar sign is not a quote introducer")
    func bareDollarSign() throws {
        #expect(
            try ShellLexer.tokenize("curl 'https://x.example?a=$b'")
                == ["curl", "https://x.example?a=$b"])
        #expect(try ShellLexer.tokenize("$HOME") == ["$HOME"])
    }

    // MARK: - Dialect detection

    @Test(
        "detects the dialect",
        arguments: [
            ("curl 'https://x.example'", ShellLexer.Dialect.posix),
            ("curl.exe \"https://x.example\"", .windowsCmd),
            ("curl \"https://x.example\" ^\n  -H \"a: b\"", .windowsCmd),
            ("curl \"https://x.example\" -H \"x: a^%^b\"", .windowsCmd),
            // A caret inside a value is not evidence of cmd on its own.
            ("curl 'https://x.example' -H 'x: a^b'", .posix),
        ]
    )
    func dialectDetection(input: String, expected: ShellLexer.Dialect) {
        #expect(ShellLexer.Dialect.detect(in: input) == expected)
    }

    // MARK: - Windows cmd

    @Test("cmd quoting")
    func windowsQuoting() throws {
        let tokens = try ShellLexer.tokenize(
            #"curl.exe "https://x.example" -H "a: \"quoted\"""#, dialect: .windowsCmd)
        #expect(tokens == ["curl.exe", "https://x.example", "-H", #"a: "quoted""#])
    }

    @Test("a doubled quote inside a cmd string is a literal quote")
    func windowsDoubledQuote() throws {
        #expect(try ShellLexer.tokenize(#""a""b""#, dialect: .windowsCmd) == [#"a"b"#])
    }

    @Test("cmd caret continuations and percent escapes")
    func windowsCaretAndPercent() throws {
        let tokens = try ShellLexer.tokenize("curl.exe ^\n  \"a^%^b\"", dialect: .windowsCmd)
        #expect(tokens == ["curl.exe", "a%b"])
    }

    // MARK: - Refusals

    @Test(
        "refuses shell control syntax when unquoted",
        arguments: ["a | b", "a && b", "a ; b", "a `b`", "a $(b)", "a & b"]
    )
    func refusesControlSyntax(input: String) {
        #expect(throws: ShellLexer.LexError.self) {
            _ = try ShellLexer.tokenize(input)
        }
    }

    @Test(
        "the same characters are fine inside single quotes",
        arguments: ["'a | b'", "'a && b'", "'a ; b'", "'a `b`'", "'a $(b)'", "'a & b'"]
    )
    func allowsControlSyntaxInSingleQuotes(input: String) throws {
        #expect(try ShellLexer.tokenize(input).count == 1)
    }

    /// Double quotes do not disable substitution, so these must still be refused. Single quotes do,
    /// so the equivalent above is allowed. Getting this backwards in either direction is a bug.
    @Test(
        "substitution is still refused inside double quotes",
        arguments: [#""a $(b)""#, #""a `b`""#]
    )
    func refusesSubstitutionInDoubleQuotes(input: String) {
        #expect(throws: ShellLexer.LexError.self) {
            _ = try ShellLexer.tokenize(input)
        }
    }

    @Test("pipes and separators ARE allowed inside double quotes")
    func allowsPipesInDoubleQuotes() throws {
        // Not substitution, so not dangerous: `-H "X-Pipe: a|b"` is a legitimate header.
        #expect(try ShellLexer.tokenize(#""a|b""#) == ["a|b"])
        #expect(try ShellLexer.tokenize(#""a;b""#) == ["a;b"])
    }

    @Test(
        "unterminated quotes are reported",
        arguments: ["'unclosed", #""unclosed"#, #"$'unclosed"#]
    )
    func unterminatedQuotes(input: String) {
        #expect(throws: ShellLexer.LexError.self) {
            _ = try ShellLexer.tokenize(input)
        }
    }

    @Test("an escaped control character is not treated as control syntax")
    func escapedControlCharacter() throws {
        #expect(try ShellLexer.tokenize(#"a\|b"#) == ["a|b"])
    }
}
