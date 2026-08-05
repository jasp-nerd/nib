import Foundation

/// Turns an authored `HTTPRequestSpec` into a resolved `SendPlan`.
///
/// This is the boundary that makes the whole design work. Everything template-shaped happens
/// here — variable substitution, path parameters, auth resolution, content-type defaulting — so
/// that `NibHTTP` receives a plan with no `{{vars}}` in it and needs no knowledge of
/// environments or collections.
///
/// A pure function: no I/O except reading a file body's size is *not* done here either (a
/// `.binary` body becomes a file URL and the engine streams it). No clock and no randomness
/// beyond the injected `DynamicValues`.
public enum SendPlanBuilder {

    public struct Output: Sendable {
        public var plan: SendPlan
        /// Every `{{name}}` we could not resolve. The UI warns before sending rather than
        /// blocking: a request with one bad variable should still be sendable so the user can
        /// see the 400 and understand why.
        public var unresolved: [VariableResolver.Unresolved]
        /// Things we changed or could not do exactly as asked. Surfaced, never hidden.
        public var notes: [String]

        public var isFullyResolved: Bool { unresolved.isEmpty }
    }

    public enum BuildError: Error, Sendable, Equatable {
        case emptyURL
        case invalidURL(String)
        case unsupportedBody(String)
        /// A multipart or binary body names a file that is not there.
        case missingFile(String)
    }

    /// A body plus the `Content-Type` that describes it.
    ///
    /// Paired because multipart cannot separate them: the header carries the boundary, which is
    /// only known once the body has been assembled.
    struct BuiltBody {
        var body: SendPlan.Body
        var contentType: String?
    }

    public static func build(
        _ spec: HTTPRequestSpec,
        scope: VariableScope,
        inheritedAuth: AuthSpec = .none,
        dynamic: DynamicValues = .live
    ) throws -> Output {
        var unresolved: [VariableResolver.Unresolved] = []
        var notes: [String] = []

        // One resolver closure, so every field reports unresolved names into the same list.
        func resolve(_ template: String) -> String {
            let result = VariableResolver.resolve(template, in: scope, dynamic: dynamic)
            for item in result.unresolved where !unresolved.contains(item) {
                unresolved.append(item)
            }
            return result.text
        }

        var components = try buildURL(spec, params: spec.params, resolve: resolve, notes: &notes)

        // MARK: Headers

        var headers = spec.headers
            .filter(\.enabled)
            .map { SendPlan.Header(name: resolve($0.name), value: resolve($0.value)) }

        // MARK: Auth

        let effectiveAuth = spec.auth == .inherit ? inheritedAuth : spec.auth
        applyAuth(
            effectiveAuth,
            headers: &headers,
            components: &components,
            resolve: resolve,
            notes: &notes
        )

        guard let url = components.url else {
            throw BuildError.invalidURL(components.string ?? spec.url)
        }

        // MARK: Body

        let built = try buildBody(spec.body, resolve: resolve)
        var body = built.body

        // GET-with-body is legal but surprising, so it is opt-in. Dropping it silently would be
        // worse than either alternative, hence the note.
        if body != .none, !spec.method.conventionallyCarriesBody, !spec.settings.sendBodyOnGet {
            body = .none
            notes.append(
                "Body not sent: \(spec.method) does not normally carry one. "
                    + "Enable \"Send body on GET\" in request settings to force it."
            )
        }

        if let contentType = built.contentType,
            body != .none,
            !headers.contains(where: {
                $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame
            })
        {
            headers.append(SendPlan.Header(name: "Content-Type", value: contentType))
        }

        let plan = SendPlan(
            method: spec.method,
            url: url,
            headers: headers,
            body: body,
            redirects: SendPlan.RedirectPolicy(
                follow: spec.settings.followRedirects,
                maximum: spec.settings.maximumRedirects,
                preserveMethod: spec.settings.preserveMethodOnRedirect
            ),
            tls: SendPlan.TLSPolicy(verify: spec.settings.verifyTLS),
            timeout: .milliseconds(spec.settings.timeoutMilliseconds)
        )

        if !spec.settings.verifyTLS {
            notes.append("TLS certificate verification is disabled for this request.")
        }

        return Output(plan: plan, unresolved: unresolved, notes: notes)
    }

    // MARK: - URL construction

    /// Resolve the URL template, default the scheme, substitute path parameters, and merge query
    /// parameters. Auth may still add a query item afterwards, so this returns components rather
    /// than a finished `URL`.
    private static func buildURL(
        _ spec: HTTPRequestSpec,
        params: [Param],
        resolve: (String) -> String,
        notes: inout [String]
    ) throws -> URLComponents {
        let resolvedURL = resolve(spec.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedURL.isEmpty else { throw BuildError.emptyURL }

        guard var components = URLComponents(string: resolvedURL) else {
            throw BuildError.invalidURL(resolvedURL)
        }

        // A bare "example.com/users" is what people paste. Defaulting to https rather than
        // rejecting it is the kinder behaviour, and it is what every other client does.
        if components.scheme == nil {
            guard let reparsed = URLComponents(string: "https://" + resolvedURL) else {
                throw BuildError.invalidURL(resolvedURL)
            }
            components = reparsed
            notes.append("No scheme given; assumed https.")
        }

        components.path = substitutePathParams(
            in: components.path,
            params: params,
            resolve: resolve,
            notes: &notes
        )

        // Query params from the table are appended to whatever the URL already carried, so a
        // pasted URL with `?a=1` keeps it.
        let queryItems =
            params
            .filter { $0.kind == .query && $0.enabled }
            .map { URLQueryItem(name: resolve($0.name), value: resolve($0.value)) }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        return components
    }

    // MARK: - Path parameters

    /// Replace `:name` tokens in the path.
    ///
    /// Operates on `URLComponents.path` specifically, never the whole URL string, so the `:` in
    /// `https://` and in a `host:port` can never be mistaken for a parameter.
    private static func substitutePathParams(
        in path: String,
        params: [Param],
        resolve: (String) -> String,
        notes: inout [String]
    ) -> String {
        guard path.contains(":") else { return path }

        let lookup = Dictionary(
            params.filter { $0.kind == .path && $0.enabled }
                .map { (resolve($0.name), resolve($0.value)) },
            uniquingKeysWith: { _, last in last }
        )

        var unmatched: [String] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)

        let replaced = segments.map { segment -> String in
            guard segment.hasPrefix(":"), segment.count > 1 else { return String(segment) }
            let name = String(segment.dropFirst())
            guard let value = lookup[name] else {
                unmatched.append(name)
                return String(segment)
            }
            // Path values must not smuggle in extra segments or query strings.
            return value.addingPercentEncoding(withAllowedCharacters: .nibPathSegment) ?? value
        }

        if !unmatched.isEmpty {
            notes.append(
                "Path parameter(s) with no value: \(unmatched.map { ":\($0)" }.joined(separator: ", "))."
            )
        }

        return replaced.joined(separator: "/")
    }

    // MARK: - Auth

    private static func applyAuth(
        _ auth: AuthSpec,
        headers: inout [SendPlan.Header],
        components: inout URLComponents,
        resolve: (String) -> String,
        notes: inout [String]
    ) {
        switch auth {
        case .none, .inherit:
            // `.inherit` reaching here means nothing up the chain defined auth either.
            break

        case .bearer(let token):
            headers.append(
                SendPlan.Header(name: "Authorization", value: "Bearer \(resolve(token))"))

        case .basic(let username, let password):
            let pair = "\(resolve(username)):\(resolve(password))"
            let encoded = Data(pair.utf8).base64EncodedString()
            headers.append(SendPlan.Header(name: "Authorization", value: "Basic \(encoded)"))

        case .apiKey(let name, let value, let placement):
            let resolvedName = resolve(name)
            let resolvedValue = resolve(value)
            switch placement {
            case .header:
                headers.append(SendPlan.Header(name: resolvedName, value: resolvedValue))
            case .query:
                components.queryItems =
                    (components.queryItems ?? [])
                    + [URLQueryItem(name: resolvedName, value: resolvedValue)]
                notes.append("API key sent in the query string, where it may be logged by servers.")
            }
        }
    }

    // MARK: - Body

    private static func buildBody(
        _ spec: BodySpec,
        resolve: (String) -> String
    ) throws -> BuiltBody {
        if case .multipart(let parts) = spec {
            return try buildMultipart(parts, resolve: resolve)
        }
        return BuiltBody(
            body: try bodyBytes(spec, resolve: resolve),
            contentType: defaultContentType(for: spec))
    }

    private static func bodyBytes(
        _ spec: BodySpec,
        resolve: (String) -> String
    ) throws -> SendPlan.Body {
        switch spec {
        case .none:
            return .none

        case .raw(let text, _):
            let resolved = resolve(text)
            return resolved.isEmpty ? .none : .bytes(Data(resolved.utf8))

        case .urlEncoded(let fields):
            let active = fields.filter(\.enabled)
            guard !active.isEmpty else { return .none }
            // Form encoding is not URL-query encoding: space is `+` and `&`, `=`, `+` must all
            // be escaped. URLComponents will not do this for us correctly.
            let encoded =
                active
                .map { formEncode(resolve($0.name)) + "=" + formEncode(resolve($0.value)) }
                .joined(separator: "&")
            return .bytes(Data(encoded.utf8))

        case .graphQL(let query, let variables):
            // `variables` is a JSON string in Postman's format. Embed it as a JSON *value* if it
            // parses, and as a string if it does not — mangling it would silently break the
            // request.
            let resolvedQuery = resolve(query)
            let resolvedVariables = resolve(variables)
            var payload: [String: Any] = ["query": resolvedQuery]
            if !resolvedVariables.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let parsed = try? JSONSerialization.jsonObject(
                    with: Data(resolvedVariables.utf8))
                {
                    payload["variables"] = parsed
                } else {
                    payload["variables"] = resolvedVariables
                }
            }
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            return .bytes(data)

        case .binary(let path):
            let resolved = resolve(path)
            guard !resolved.isEmpty else { return .none }
            guard FileManager.default.fileExists(atPath: resolved) else {
                throw BuildError.missingFile(resolved)
            }
            // A file URL, not bytes: the engine streams it so a large upload never counts
            // against the app's memory budget.
            return .file(URL(fileURLWithPath: resolved))

        case .multipart:
            // Unreachable: `buildBody` routes multipart before it gets here.
            return .none
        }
    }

    private static func defaultContentType(for spec: BodySpec) -> String? {
        switch spec {
        case .none: nil
        case .raw(_, let language): language.contentType
        case .urlEncoded: "application/x-www-form-urlencoded"
        case .graphQL: "application/json"
        case .binary: "application/octet-stream"
        case .multipart: nil  // carried on `BuiltBody`, because it includes the boundary
        }
    }

    /// `application/x-www-form-urlencoded` percent-encoding.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: " ", with: "+")
    }
}

extension CharacterSet {
    /// Safe inside a single path segment. Deliberately excludes `/` so a path parameter value
    /// cannot inject extra segments, and `?` and `#` so it cannot start a query or fragment.
    fileprivate static let nibPathSegment: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return set
    }()
}
