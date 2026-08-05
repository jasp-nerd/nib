import Foundation

/// Where things live on disk.
///
/// Nib keeps **two** stores, and keeping them apart is the most important rule in this
/// package:
///
///   1. The **collection folder** — chosen by the user, expected to be a git repo. Requests,
///      folders, and environments *without secret values*. Everything here is meant to be
///      committed, reviewed and diffed. That is the product's second pitch after Postman
///      import, so it has to stay clean.
///
///   2. **Application Support** — response history, cookie jars, window state, recent
///      folders, security-scoped bookmarks. High-churn, private, uninteresting to a reviewer.
///
/// Writing history into someone's git repo would poison the git-friendly claim on day one,
/// so nothing from store 2 may ever be written into store 1.
public enum StoreLocations {
    /// Bumped only for an on-disk format change that older builds cannot read. Written into
    /// every file so a future version can migrate rather than guess.
    public static let formatVersion = 1

    /// Keychain service for secret environment values. Accounts are
    /// `<collectionUUID>/<environmentName>/<key>`, so a repo cloned onto another machine
    /// correctly finds nothing and prompts, rather than silently sending an empty token.
    public static let keychainService = "app.nib.secret"

    // MARK: - Collection folder (store 1: git-tracked, user-owned)

    public static let collectionMetadataFilename = "collection.json"
    public static let folderMetadataFilename = "folder.json"
    public static let environmentsDirectoryName = "environments"

    public static let requestFileExtension = "req.json"
    public static let environmentFileExtension = "env.json"

    /// Request bodies live in a sibling file, never inlined into the request JSON.
    ///
    /// This is what makes the git story actually work: a 40-line JSON body escaped into a
    /// single `"raw": "{\n \"a\"…"` string is an unreadable diff, whereas a sibling file
    /// diffs line by line like any other source file.
    public static func bodyFilename(forRequestNamed name: String) -> String {
        "\(name).req.body.json"
    }

    // MARK: - Application Support (store 2: private, high-churn)

    public static func applicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Nib", isDirectory: true)
    }

    public static func historyDirectory() throws -> URL {
        try applicationSupport().appendingPathComponent("History", isDirectory: true)
    }

    public static func cookiesDirectory() throws -> URL {
        try applicationSupport().appendingPathComponent("Cookies", isDirectory: true)
    }

    // MARK: - Canonical encoding

    /// The one encoder used for everything written into a collection folder.
    ///
    /// Determinism is a hard requirement, not a nicety: the same model must produce
    /// byte-identical output every time, or every save would produce spurious git churn and
    /// the "diff your requests" pitch collapses. `sortedKeys` handles dictionary ordering,
    /// `withoutEscapingSlashes` keeps URLs readable, and callers append a trailing newline
    /// so the files behave like normal text files in a diff.
    public static func makeCanonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Encode for on-disk storage: canonical JSON plus a trailing newline.
    public static func encodeForDisk<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeCanonicalEncoder().encode(value)
        if data.last != UInt8(ascii: "\n") {
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
