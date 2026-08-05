import Foundation

/// Splits a command line into words the way a shell would.
///
/// This is the foundation of cURL import, and it exists because the strings people paste come
/// straight out of browser devtools in three mutually incompatible dialects:
///
/// - **Chrome / Safari on macOS**: POSIX quoting, `\` line continuations, `$'…'` for bytes that
///   need escaping.
/// - **Firefox**: POSIX, but tends to single-quote everything and emits `--compressed`.
/// - **Chrome "Copy as cURL (cmd)" on Windows**: `curl.exe`, `^` line continuations, `"` quoting
///   with `\"` inside, and `^%^` to escape `%`.
///
/// Deliberately NOT a shell. It refuses anything that would require executing something — pipes,
/// `&&`, `;`, subshells, backticks — rather than trying to interpret it. Silently ignoring a pipe
/// would import half a command and look like it worked.
///
/// The tokenizers themselves live in `ShellLexer+Tokenizers.swift`.
public enum ShellLexer {

    public enum Dialect: Sendable, Equatable {
        case posix
        case windowsCmd

        /// Guess from the shape of the input.
        ///
        /// Windows is the special case, so look for its markers and default to POSIX otherwise.
        public static func detect(in input: String) -> Dialect {
            if input.contains("curl.exe") { return .windowsCmd }
            // `^` at end of line is the cmd continuation character. A bare `^` mid-string is not
            // enough evidence -- it appears in legitimate header values.
            if input.contains("^\n") || input.contains("^\r\n") { return .windowsCmd }
            if input.contains("^%^") { return .windowsCmd }
            return .posix
        }
    }

    public enum LexError: Error, Sendable, Equatable {
        case unterminatedQuote(Character)
        /// The input contains shell control syntax we will not interpret.
        case unsupportedShellSyntax(String)
    }

    /// Tokenize `input`, auto-detecting the dialect.
    public static func tokenize(_ input: String) throws -> [String] {
        try tokenize(input, dialect: Dialect.detect(in: input))
    }

    public static func tokenize(_ input: String, dialect: Dialect) throws -> [String] {
        try rejectShellControlSyntax(input)

        switch dialect {
        case .posix: return try tokenizePOSIX(input)
        case .windowsCmd: return try tokenizeWindowsCmd(input)
        }
    }

    // MARK: - Refusing what we cannot honestly handle

    /// Quoting state while scanning for control syntax.
    private enum Quoting {
        case none
        case single
        case double
    }

    /// Reject control syntax rather than silently dropping it.
    ///
    /// Quoting matters, and getting it wrong in either direction is a bug:
    ///
    /// - **Single quotes are fully literal.** `-H 'X: a|b'` and `-d 'a && b'` are ordinary and must
    ///   not trip this.
    /// - **Double quotes are NOT literal.** `$(…)` and backticks still execute inside them, so
    ///   `-H "token: $(cat secret)"` has to be refused. An earlier version skipped every control
    ///   check inside any quote and let this straight through — which would have imported a header
    ///   containing a literal `$(cat secret)` and sent it to the server.
    static func rejectShellControlSyntax(_ input: String) throws {
        var quoting = Quoting.none
        var escaped = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]

            if escaped {
                escaped = false
                index = input.index(after: index)
                continue
            }

            if character == "\\", quoting != .single {
                escaped = true
                index = input.index(after: index)
                continue
            }

            switch quoting {
            case .single:
                if character == "'" { quoting = .none }

            case .double:
                if character == "\"" {
                    quoting = .none
                } else if let error = substitutionError(in: input, at: index) {
                    // Command substitution is live inside double quotes.
                    throw error
                }

            case .none:
                if character == "'" {
                    quoting = .single
                } else if character == "\"" {
                    quoting = .double
                } else if let error = controlSyntaxError(in: input, at: index) {
                    throw error
                }
            }

            index = input.index(after: index)
        }
    }

    /// `$(…)` and backticks — the two forms that would run a command.
    private static func substitutionError(in input: String, at index: String.Index) -> LexError? {
        let substitution = LexError.unsupportedShellSyntax(
            "This command substitutes a shell command. Nib will not run shell commands.")

        switch input[index] {
        case "`":
            return substitution
        case "$":
            let next = input.index(after: index)
            return next < input.endIndex && input[next] == "(" ? substitution : nil
        default:
            return nil
        }
    }

    /// Everything we refuse when unquoted: substitution plus pipes and command separators.
    private static func controlSyntaxError(in input: String, at index: String.Index) -> LexError? {
        if let error = substitutionError(in: input, at: index) { return error }

        switch input[index] {
        case "|":
            return .unsupportedShellSyntax(
                "This command pipes its output somewhere. Paste just the curl part.")
        case ";", "&":
            // `&&`, `;`, and a trailing `&`. A lone `&` inside a URL is always quoted in practice.
            return .unsupportedShellSyntax(
                "This looks like more than one command. Paste just the curl part.")
        default:
            return nil
        }
    }
}
