import Foundation
import NibCore

/// The last few responses for each request.
///
/// **Store 2, and that is the whole point.** History is high-churn, personal, and often contains
/// live data from a production API. Writing it into the user's collection folder would put response
/// payloads into their git repo — which would poison the "your requests are files you can commit"
/// pitch on the first day someone ran `git add .`. It goes to Application Support and stays there.
///
/// One file per request rather than one index. A request's history can be read, rewritten or
/// deleted without touching any other, so there is no shared file to lock and a corrupt entry
/// costs one request's history instead of all of it.
public actor HistoryStore {

    /// Per request. Twenty is enough to answer "what did this return before I changed it" and small
    /// enough that the file stays a few hundred kilobytes at worst.
    public static let limit = 20

    /// Bodies are truncated to this before being written. History is for recognising a response,
    /// not for archiving it — keeping a 20 MB payload twenty times over would put half a gigabyte
    /// in Application Support for one request.
    public static let bodyPreviewLimit = 64 * 1024

    public struct Entry: Sendable, Codable, Hashable, Identifiable {
        public var id: String
        public var date: Date
        public var method: String
        public var url: String
        public var status: Int
        public var durationMilliseconds: Double
        public var byteCount: Int64
        /// The first `bodyPreviewLimit` bytes, as text.
        public var bodyPreview: String
        public var isBodyTruncated: Bool

        public init(
            id: String,
            date: Date,
            method: String,
            url: String,
            status: Int,
            durationMilliseconds: Double,
            byteCount: Int64,
            bodyPreview: String,
            isBodyTruncated: Bool
        ) {
            self.id = id
            self.date = date
            self.method = method
            self.url = url
            self.status = status
            self.durationMilliseconds = durationMilliseconds
            self.byteCount = byteCount
            self.bodyPreview = bodyPreview
            self.isBodyTruncated = isBodyTruncated
        }
    }

    private let directory: URL

    /// The directory is injectable so tests never write into the real Application Support folder.
    public init(directory: URL? = nil) throws {
        self.directory = try directory ?? StoreLocations.historyDirectory()
    }

    // MARK: - Reading

    /// Newest first, which is the order the UI wants and the order the file is kept in.
    public func entries(forRequest requestID: NodeID) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL(for: requestID)),
            let entries = try? JSONDecoder.history.decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    // MARK: - Writing

    /// Prepend an entry and drop anything past the limit.
    ///
    /// Failures are swallowed deliberately. History is a convenience; a full disk or a permissions
    /// problem in Application Support must never turn into an error on a request that actually
    /// succeeded.
    public func record(_ entry: Entry, forRequest requestID: NodeID) {
        var entries = entries(forRequest: requestID)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit {
            entries.removeLast(entries.count - Self.limit)
        }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.history.encode(entries) else { return }
        try? data.write(to: fileURL(for: requestID), options: [.atomic])
    }

    public func clear(forRequest requestID: NodeID) {
        try? FileManager.default.removeItem(at: fileURL(for: requestID))
    }

    /// Remove history for requests that no longer exist.
    ///
    /// Called after a collection loads. Without it, deleting a request leaves its responses in
    /// Application Support forever — invisible, and still containing whatever the API returned.
    public func prune(keeping liveRequestIDs: Set<NodeID>) {
        let keep = Set(liveRequestIDs.map { $0.rawValue + ".json" })
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        for entry in entries
        where entry.pathExtension == "json" && !keep.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func fileURL(for requestID: NodeID) -> URL {
        // The id is a ULID from our own alphabet — Crockford base32, no path separators — so it is
        // safe as a filename without sanitising. Anything else would be, too, but not obviously.
        directory.appendingPathComponent("\(requestID.rawValue).json")
    }
}

extension JSONEncoder {
    /// Not the canonical encoder. This is store 2: nobody diffs it, so ISO dates and compact output
    /// beat pretty-printed determinism.
    fileprivate static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
