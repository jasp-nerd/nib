import Foundation
import NibCore

/// A response, prepared for display.
///
/// Formatting happens once here rather than in a view body, which would recompute it on every
/// redraw — pretty-printing a few megabytes of JSON per frame is exactly the kind of thing that
/// makes an app feel slow for no reason.
///
/// **`nonisolated`, and built via `make` off the main actor.** `NibUI` sets
/// `.defaultIsolation(MainActor.self)`, so without this the initialiser below — memory-mapping a
/// file, copying up to a megabyte, parsing JSON and re-serialising it — ran on the main actor at
/// exactly the moment the response landed. That is tens to hundreds of milliseconds of hang in the
/// one operation the app exists to perform, and it contradicted `docs/architecture.md`: "nothing
/// blocks the main actor; networking, parsing and file I/O all live in nonisolated packages."
nonisolated public struct ResponseViewModel: Sendable, Identifiable {
    /// Identity for "is this the same response I am already showing". The pane uses it to avoid
    /// re-pushing a megabyte of text into the text view on an unrelated redraw, which would also
    /// drop the user's selection.
    public let id = UUID()
    public let status: Int
    public let statusText: String
    public let headers: [SendPlan.Header]
    public let timing: SendEvent.Timing
    public let hops: [SendEvent.Hop]
    public let networkProtocol: String?
    public let byteCount: Int64

    /// The body, pretty-printed when it parses as JSON.
    ///
    /// Always pretty-print before display: minified JSON arrives as one enormous line, and one
    /// enormous line is the shape TextKit handles worst.
    ///
    /// This is the text `Copy` puts on the pasteboard, so it is the *true* text. `displayText` is
    /// the one the view shows.
    public let bodyText: String
    /// Exactly what arrived, before pretty-printing. What the Raw tab shows.
    public let rawText: String
    public let isPrettyPrinted: Bool
    /// Whether to colour it.
    ///
    /// Separate from `isPrettyPrinted`, and the difference matters at exactly the size where it is
    /// most visible: a body over `displayLimit` is cut mid-structure, so it no longer parses and
    /// cannot be pretty-printed — but `JSONTokenizer` is line-scoped and does not need the document
    /// to be well-formed. Tying colour to "did it parse" left every large response, the ones people
    /// most need help reading, rendered in flat grey.
    public let looksLikeJSON: Bool
    /// True when the payload was spilled to a file and is too large to show in full here.
    public let isTruncated: Bool
    public let cookies: [Cookie]

    public static let displayLimit = 1024 * 1024

    /// Hard-wrap width for a line that has no natural breaks.
    ///
    /// Pretty-printing takes care of JSON. This is for everything else — minified JavaScript, a
    /// base64 blob, an SVG — where a single line can be the whole body. TextKit lays out a line as
    /// a unit, so one 4 MB line is a single layout operation that stalls the frame no matter how
    /// little of it is on screen.
    public static let hardWrapWidth = 4000

    /// What the text view is given: `bodyText`, with over-long lines broken up.
    ///
    /// Kept separate from `bodyText` so copying gives back what the server actually sent. A copy
    /// button that inserts newlines into someone's payload is worse than no copy button.
    public let displayText: String

    /// A `Set-Cookie` header, parsed. A struct rather than `HTTPCookie` because this type has to be
    /// `Sendable` to cross back to the main actor, and `HTTPCookie` is a non-Sendable class.
    public struct Cookie: Sendable, Hashable {
        public let name: String
        public let value: String
        public let domain: String
        public let path: String
        public let expires: Date?
        public let isSecure: Bool
        public let isHTTPOnly: Bool
        public let sameSite: String?
        /// `Secure`, but the response came over plain HTTP — so a browser would throw it away.
        /// Shown rather than hidden; see `cookies(in:for:)`.
        public let isDiscardedAsInsecure: Bool
    }

    /// Build off the main actor.
    ///
    /// `@concurrent` puts the work on the global executor rather than inheriting the caller's
    /// isolation. Both inputs are already `Sendable`, so nothing else has to change.
    @concurrent
    public static func make(result: SendEvent.Result, requestURL: URL) async -> ResponseViewModel {
        ResponseViewModel(result: result, requestURL: requestURL)
    }

    public init(result: SendEvent.Result, requestURL: URL) {
        status = result.head.status
        statusText = Self.statusText(for: result.head.status)
        headers = result.head.headers.sorted { $0.name.lowercased() < $1.name.lowercased() }
        timing = result.timing
        hops = result.hops
        networkProtocol = result.networkProtocol
        cookies = Self.cookies(in: result.head.headers, for: requestURL)

        let raw: Data
        switch result.payload {
        case .memory(let data):
            raw = data
            byteCount = Int64(data.count)
        case .file(let url, let count):
            byteCount = count
            // Memory-mapped rather than read: the file can be hundreds of megabytes, and we only
            // ever display the first slice of it.
            if let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) {
                raw = Data(mapped.prefix(Self.displayLimit))
            } else {
                raw = Data()
            }
        }

        isTruncated = byteCount > Int64(Self.displayLimit)
        let shown = raw.count > Self.displayLimit ? Data(raw.prefix(Self.displayLimit)) : raw

        let decoded =
            String(data: shown, encoding: .utf8) ?? "<\(byteCount) bytes of binary data>"
        rawText = decoded

        looksLikeJSON = Self.looksLikeJSON(decoded, headers: headers)

        if let pretty = Self.prettyPrintJSON(shown) {
            bodyText = pretty
            isPrettyPrinted = true
        } else {
            // Not JSON, so Pretty and Raw are the same text. Assigning the same string shares
            // storage rather than copying it.
            bodyText = decoded
            isPrettyPrinted = false
        }

        displayText = Self.hardWrapping(bodyText, at: Self.hardWrapWidth)
    }

    // MARK: - Preparation

    /// Break lines longer than `width` so no single line is a pathological layout unit.
    ///
    /// Splits on `Character`, not on UTF-16 offsets — cutting between the halves of a surrogate
    /// pair would produce replacement characters in the middle of someone's payload, and an emoji
    /// exactly 4000 units into a line is not a rare enough case to get wrong.
    ///
    /// Returns the input unchanged when nothing is over the limit, which is the overwhelmingly
    /// common case and costs one scan.
    static func hardWrapping(_ text: String, at width: Int) -> String {
        guard text.utf16.count > width else { return text }

        var result: [Substring] = []
        var didWrap = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.utf16.count > width else {
                result.append(line)
                continue
            }
            didWrap = true

            var chunkStart = line.startIndex
            var index = line.startIndex
            var units = 0

            while index < line.endIndex {
                let size = line[index].utf16.count
                if units + size > width {
                    result.append(line[chunkStart..<index])
                    chunkStart = index
                    units = 0
                }
                units += size
                index = line.index(after: index)
            }
            if chunkStart < line.endIndex {
                result.append(line[chunkStart..<line.endIndex])
            }
        }

        return didWrap ? result.joined(separator: "\n") : text
    }

    /// Every cookie the response set.
    ///
    /// ## Why this is not one line of Foundation
    ///
    /// `HTTPURLResponse.allHeaderFields` is a dictionary, so duplicate headers are already
    /// **merged** by the time the engine sees them — two `Set-Cookie` headers arrive as one value
    /// joined with ", ". That is fine for most headers and wrong for this one, because an `Expires`
    /// date contains a comma of its own:
    ///
    ///     session=abc; Path=/; HttpOnly, tracking=xyz; Expires=Wed, 21 Oct 2026 07:28:00 GMT
    ///
    /// Handing that straight to `HTTPCookie.cookies(withResponseHeaderFields:for:)` does not
    /// produce two cookies. Measured against a server sending exactly the pair above, it produced
    /// **one**, and not the first — the `session` cookie, the one with the security flags anybody
    /// would open this tab to check, silently disappeared.
    ///
    /// So the joined value is split first, on the only comma that reliably separates cookies: one
    /// followed by something shaped like `name=`. A date's comma is followed by ` 21 Oct`, which is
    /// not. Recorded in `docs/http-fidelity.md` with the rest of the deviations.
    ///
    /// ## And a second drop, for a different reason
    ///
    /// `HTTPCookie` enforces the `Secure` attribute at parse time: ask it to parse a `Secure`
    /// cookie against an `http://` URL and it returns nothing, with no error. Measured — the same
    /// pair of cookies parses as two against `https://127.0.0.1` and as one against
    /// `http://127.0.0.1`.
    ///
    /// Correct for a browser, wrong for this tab. "My server set a Secure cookie and I am on
    /// localhost over plain HTTP" is a real misconfiguration people come here to find, and a tab
    /// that answers by showing nothing at all is the least useful possible response. So parsing
    /// happens against an https-normalised URL and the cookie is shown, flagged with what a browser
    /// would actually do with it.
    private static func cookies(in headers: [SendPlan.Header], for url: URL) -> [Cookie] {
        let overPlainHTTP = url.scheme?.lowercased() == "http"
        let parseURL = overPlainHTTP ? secured(url) : url

        return
            headers
            .filter { $0.name.lowercased() == "set-cookie" }
            .flatMap { splitJoinedCookies($0.value) }
            .flatMap { value in
                HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: parseURL)
            }
            .map { cookie in
                Cookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    expires: cookie.expiresDate,
                    isSecure: cookie.isSecure,
                    isHTTPOnly: cookie.isHTTPOnly,
                    // `sameSitePolicy` is `HTTPCookieStringPolicy?`, whose raw value is the word
                    // the server sent.
                    sameSite: cookie.sameSitePolicy?.rawValue,
                    isDiscardedAsInsecure: overPlainHTTP && cookie.isSecure
                )
            }
    }

    /// The same URL over https, purely so `HTTPCookie` will parse a `Secure` cookie for us.
    /// Never used to send anything.
    private static func secured(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    /// Is this worth colouring?
    ///
    /// Content type first, because it is the server's own answer. Falling back to the first
    /// non-space character catches the servers that send `text/plain` for JSON, which is common
    /// enough to be worth two lines.
    private static func looksLikeJSON(_ text: String, headers: [SendPlan.Header]) -> Bool {
        let contentType =
            headers.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if contentType.contains("json") { return true }
        if !contentType.isEmpty && !contentType.hasPrefix("text/") { return false }

        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    /// Split a comma-joined run of `Set-Cookie` values back into individual ones.
    ///
    /// A comma starts a new cookie only when what follows looks like `name=`, using the RFC 6265
    /// token character set. Everything else — most importantly the comma inside an `Expires` date —
    /// belongs to the cookie being read.
    static func splitJoinedCookies(_ header: String) -> [String] {
        let units = Array(header)
        var parts: [String] = []
        var start = 0

        for index in units.indices where units[index] == "," {
            guard startsCookie(units, at: index + 1) else { continue }
            parts.append(String(units[start..<index]))
            start = index + 1
        }
        parts.append(String(units[start...]))

        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Does a `name=` pair begin here, once leading spaces are skipped?
    private static func startsCookie(_ units: [Character], at index: Int) -> Bool {
        var cursor = index
        while cursor < units.count, units[cursor] == " " { cursor += 1 }

        let nameStart = cursor
        while cursor < units.count, isTokenCharacter(units[cursor]) { cursor += 1 }

        // A name of at least one character, then an equals sign. `Expires=Wed, 21 Oct` fails here
        // because `21 Oct 2026 07:28:00 GMT` reaches a `;` or the end without an `=`.
        return cursor > nameStart && cursor < units.count && units[cursor] == "="
    }

    /// RFC 6265 token characters — `separators` from RFC 2616 excluded.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return "!#$%&'*+-.^_`|~".contains(character)
    }

    private static func prettyPrintJSON(_ data: Data) -> String? {
        guard !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data),
            let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: formatted, encoding: .utf8)
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var isRedirect: Bool { (300..<400).contains(status) }
    public var isError: Bool { status >= 400 }

    public var durationText: String {
        let ms =
            Double(timing.total.components.attoseconds) / 1e15
            + Double(timing.total.components.seconds) * 1000
        return ms < 1000
            ? String(format: "%.0f ms", ms)
            : String(format: "%.2f s", ms / 1000)
    }

    public var sizeText: String {
        byteCount.formatted(.byteCount(style: .binary))
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func statusText(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: ""
        }
    }
}
