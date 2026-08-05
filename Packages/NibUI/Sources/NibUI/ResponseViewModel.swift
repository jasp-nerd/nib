import Foundation
import NibCore

/// A response, prepared for display.
///
/// Formatting happens once here rather than in a view body, which would recompute it on every
/// redraw — pretty-printing a few megabytes of JSON per frame is exactly the kind of thing that
/// makes an app feel slow for no reason.
public struct ResponseViewModel: Sendable {
    public let status: Int
    public let statusText: String
    public let headers: [SendPlan.Header]
    public let timing: SendEvent.Timing
    public let hops: [SendEvent.Hop]
    public let networkProtocol: String?
    public let byteCount: Int64
    public let requestURL: URL

    /// The body, pretty-printed when it parses as JSON.
    ///
    /// Always pretty-print before display: minified JSON arrives as one enormous line and TextKit
    /// chokes on it. Phase 6 replaces this with the NSTextView + viewport highlighter path; for now
    /// it is a plain string.
    public let bodyText: String
    public let isPrettyPrinted: Bool
    /// True when the payload was spilled to a file and is too large to show in full here.
    public let isTruncated: Bool

    public static let displayLimit = 1024 * 1024

    public init(result: SendEvent.Result, requestURL: URL) {
        status = result.head.status
        statusText = Self.statusText(for: result.head.status)
        headers = result.head.headers.sorted { $0.name.lowercased() < $1.name.lowercased() }
        timing = result.timing
        hops = result.hops
        networkProtocol = result.networkProtocol
        self.requestURL = requestURL

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

        if let pretty = Self.prettyPrintJSON(shown) {
            bodyText = pretty
            isPrettyPrinted = true
        } else {
            bodyText = String(data: shown, encoding: .utf8) ?? "<\(byteCount) bytes of binary data>"
            isPrettyPrinted = false
        }
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
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .binary)
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
