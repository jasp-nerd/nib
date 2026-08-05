import Foundation
import NibCore

/// Renders a request as a `curl` command.
///
/// Two variants, and the second one is the reason this is worth building:
///
/// - **Plain** — everything, ready to run.
/// - **Redacted** — secrets replaced with shell variables and an `export` preamble. This is what
///   people paste into a GitHub issue or a Slack thread. It costs almost nothing and stops a
///   support conversation from leaking a bearer token.
public enum CurlExporter {

    public enum Style: Sendable {
        case plain
        /// Replace credential-shaped values with `$NAME` and prepend `export` lines.
        case redacted
    }

    /// Export from a resolved plan — what actually went on the wire.
    public static func export(_ plan: SendPlan, style: Style = .plain) -> String {
        var lines: [String] = []
        var exports: [String] = []

        lines.append("curl")

        // GET is curl's default, so stating it is noise.
        if plan.method != .get {
            lines.append("  -X \(plan.method.rawValue)")
        }

        let (renderedURL, urlExports) = renderURL(plan.url, style: style)
        exports.append(contentsOf: urlExports)
        lines.append("  \(quote(renderedURL))")

        for header in plan.headers {
            let rendered: String
            switch style {
            case .plain:
                rendered = "\(header.name): \(header.value)"
            case .redacted:
                if let variable = secretVariableName(for: header.name) {
                    exports.append("export \(variable)='...'")
                    rendered = "\(header.name): \(redactedValue(header, variable: variable))"
                } else {
                    rendered = "\(header.name): \(header.value)"
                }
            }
            lines.append("  -H \(quote(rendered))")
        }

        lines.append(contentsOf: bodyLines(plan.body))
        lines.append(contentsOf: optionLines(plan))

        let command = lines.joined(separator: " \\\n")
        guard style == .redacted, !exports.isEmpty else { return command }

        return exports.joined(separator: "\n") + "\n\n" + command
    }

    /// Export from an unresolved spec, resolving variables through `scope` first.
    ///
    /// Fails only if the URL is unusable; a request that could not be fully resolved still exports,
    /// because a curl line with a visible `{{baseUrl}}` in it is more useful than an error.
    public static func export(
        _ spec: HTTPRequestSpec,
        scope: VariableScope,
        style: Style = .plain
    ) throws -> String {
        let built = try SendPlanBuilder.build(spec, scope: scope)
        return export(built.plan, style: style)
    }

    // MARK: - URL

    /// Render the URL, redacting credentials carried *in the URL itself*.
    ///
    /// Redaction used to inspect header names only, which quietly defeated the whole feature:
    /// `AuthSpec.apiKey(placement: .query)` is a supported mode — `SendPlanBuilder` even warns that
    /// query-string keys end up in server logs — and the exporter then printed the resolved URL
    /// verbatim. So "Copy as cURL (Redacted)" leaked the key for exactly the auth mode most likely to
    /// have one. Userinfo (`https://user:pass@host`) had the same hole.
    private static func renderURL(_ url: URL, style: Style) -> (String, [String]) {
        guard style == .redacted,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return (url.absoluteString, [])
        }

        var exports: [String] = []

        if components.user != nil || components.password != nil {
            components.user = "$URL_USER"
            components.password = "$URL_PASSWORD"
            exports.append("export URL_USER='...'")
            exports.append("export URL_PASSWORD='...'")
        }

        if let items = components.queryItems {
            components.queryItems = items.map { item in
                guard isCredentialParameterName(item.name), item.value?.isEmpty == false else {
                    return item
                }
                let variable = shellVariableName(item.name)
                exports.append("export \(variable)='...'")
                return URLQueryItem(name: item.name, value: "$\(variable)")
            }
        }

        // `percentEncodedQuery` would escape the `$`, defeating the substitution, so build the string
        // by hand from the already-encoded pieces.
        let rendered = components.string ?? url.absoluteString
        return (rendered.replacingOccurrences(of: "%24", with: "$"), exports)
    }

    /// Query parameter names that carry credentials.
    ///
    /// Broader than the header set, because query params use snake_case and shorter names.
    private static let credentialParameterNames: Set<String> = [
        "api_key", "apikey", "api-key",
        "access_token", "accesstoken", "access-token",
        "auth_token", "authtoken", "auth-token",
        "token", "key", "secret", "password", "passwd", "pwd",
        "signature", "sig", "session", "sessionid", "session_id",
        "client_secret", "refresh_token", "id_token",
    ]

    private static func isCredentialParameterName(_ name: String) -> Bool {
        credentialParameterNames.contains(name.lowercased())
    }

    private static func shellVariableName(_ name: String) -> String {
        let mapped = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return String(mapped).uppercased()
    }

    // MARK: - Body

    private static func bodyLines(_ body: SendPlan.Body) -> [String] {
        switch body {
        case .none:
            return []
        case .bytes(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                return ["  --data-binary @body.bin"]
            }
            // --data-raw, not --data: plain --data strips newlines and treats a leading @ as a
            // filename, both of which silently corrupt a body.
            return ["  --data-raw \(quote(text))"]
        case .file(let url):
            return ["  --data-binary @\(quote(url.path))"]
        }
    }

    // MARK: - Options
    //
    // Only what differs from curl's own defaults. Restating a default makes the command longer
    // without making it clearer.

    private static func optionLines(_ plan: SendPlan) -> [String] {
        var lines: [String] = []

        // curl does not follow redirects by default, so the absence of --location is the signal.
        if plan.redirects.follow {
            lines.append("  --location")
            if plan.redirects.maximum != 10 {
                lines.append("  --max-redirs \(plan.redirects.maximum)")
            }
        }

        if !plan.tls.verify {
            lines.append("  --insecure")
        }

        let seconds = plan.timeout.components.seconds
        if seconds != 30, seconds > 0 {
            lines.append("  --max-time \(seconds)")
        }

        return lines
    }

    // MARK: - Redaction

    /// Header names whose values are credentials.
    private static let credentialHeaders: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
        "api-key",
        "apikey",
        "x-access-token",
        "x-csrf-token",
    ]

    private static func secretVariableName(for headerName: String) -> String? {
        let lowered = headerName.lowercased()
        guard credentialHeaders.contains(lowered) else { return nil }
        let sanitised =
            lowered
            .replacingOccurrences(of: "-", with: "_")
            .uppercased()
        return sanitised
    }

    /// Keep the scheme, hide the credential: `Bearer $AUTHORIZATION` rather than `$AUTHORIZATION`.
    ///
    /// The scheme is not secret and is often the thing someone needs to see to help you.
    private static func redactedValue(_ header: SendPlan.Header, variable: String) -> String {
        let schemes = ["Bearer", "Basic", "Digest", "Token"]
        for scheme in schemes where header.value.hasPrefix(scheme + " ") {
            return "\(scheme) $\(variable)"
        }
        return "$\(variable)"
    }

    // MARK: - Quoting

    /// Single-quote for POSIX shells. Always.
    ///
    /// Single quotes are literal, so the only thing needing care is an embedded single quote, which
    /// closes the string, appends an escaped quote, and reopens: `'\''`.
    ///
    /// An earlier version skipped the quotes when every character looked "shell safe", to keep
    /// simple commands readable — and that set wrongly included `&`. The result: any URL with two
    /// query parameters exported as
    ///
    ///     curl https://api.example.com/users?page=2&limit=5
    ///
    /// which a shell reads as "background `curl …?page=2`, then set `limit=5`". A silently wrong
    /// command is far worse than a slightly noisier one, and `?`, `[`, `]`, `~`, `#` were all glob or
    /// comment hazards on the same list. Readability is not worth an exported command that does the
    /// wrong thing, so there is no fast path any more.
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
