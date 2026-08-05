import Foundation
import NibCore

/// Reads and writes a collection as a folder of files.
///
/// The store's whole job is that the folder stays something a human would be happy to commit: one
/// file per request, bodies in sibling files, deterministic bytes, and no app state anywhere near it.
///
/// An `actor` because this one genuinely has mutable state to protect — the write generation used to
/// ignore our own filesystem events — and because every operation touches the disk and should not run
/// on the main actor.
public actor CollectionStore {

    public enum StoreError: Error, Sendable, Equatable {
        case notADirectory(String)
        case missingCollectionFile(String)
        case unsupportedFormatVersion(Int)
    }

    public let root: URL

    /// Incremented on every write we perform.
    ///
    /// `FolderWatcher` reports every change including ours, so without this the app would reload the
    /// tree it just saved — and a reload during an edit would discard whatever the user typed next.
    private var writeGeneration = 0

    public init(root: URL) {
        self.root = root
    }

    public var currentWriteGeneration: Int { writeGeneration }

    public struct LoadResult: Sendable {
        public var collection: NibCore.Collection
        public var environments: [NibCore.Environment]
        /// Things we skipped or adjusted. Surfaced, never swallowed.
        public var diagnostics: [String]

        public init(
            collection: NibCore.Collection,
            environments: [NibCore.Environment] = [],
            diagnostics: [String] = []
        ) {
            self.collection = collection
            self.environments = environments
            self.diagnostics = diagnostics
        }
    }

    // MARK: - Saving

    /// Write the whole collection.
    ///
    /// Every file write is atomic, so an interrupted save leaves the previous version intact rather
    /// than a truncated one. Files that no longer correspond to a node are removed, which is what
    /// makes a rename in the app show up as a rename rather than a duplicate.
    public func save(
        _ collection: NibCore.Collection, environments: [NibCore.Environment] = []
    )
        throws
    {
        writeGeneration += 1

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try write(
            DiskFormat.CollectionFile(collection),
            to: root.appendingPathComponent(StoreLocations.collectionMetadataFilename))

        try writeChildren(collection.children, into: root)
        try writeEnvironments(environments)
        try writeGitignoreIfAbsent()
    }

    private func writeChildren(_ nodes: [CollectionNode], into directory: URL) throws {
        var expected: Set<String> = [
            StoreLocations.folderMetadataFilename,
            StoreLocations.collectionMetadataFilename,
            ".gitignore",
            StoreLocations.environmentsDirectoryName,
        ]

        for node in nodes {
            switch node {
            case .request(let request):
                let sanitised = Self.sanitise(request.name)
                let requestFilename = "\(sanitised).\(StoreLocations.requestFileExtension)"
                expected.insert(requestFilename)

                let bodyFilename = Self.bodyFilename(for: request, sanitisedName: sanitised)
                if let bodyFilename {
                    expected.insert(bodyFilename)
                    try writeBody(
                        request.spec.body, to: directory.appendingPathComponent(bodyFilename))
                }

                try write(
                    DiskFormat.RequestFile(request, bodyFilename: bodyFilename),
                    to: directory.appendingPathComponent(requestFilename))

            case .folder(let folder):
                let sanitised = Self.sanitise(folder.name)
                expected.insert(sanitised)

                let subdirectory = directory.appendingPathComponent(sanitised, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: subdirectory, withIntermediateDirectories: true)
                try write(
                    DiskFormat.FolderFile(folder),
                    to: subdirectory.appendingPathComponent(StoreLocations.folderMetadataFilename))
                try writeChildren(folder.children, into: subdirectory)
            }
        }

        try removeStaleEntries(in: directory, keeping: expected)
    }

    /// Delete files we own that no longer match a node.
    ///
    /// Scoped to our own naming conventions so a stray README or a colleague's notes file is never
    /// touched. Deleting something a user put in their own repo would be unforgivable.
    private func removeStaleEntries(in directory: URL, keeping expected: Set<String>) throws {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []

        for entry in entries {
            let name = entry.lastPathComponent
            guard !expected.contains(name) else { continue }

            let isOurs =
                name.hasSuffix("." + StoreLocations.requestFileExtension)
                || name.hasSuffix(".req.body.json")
                || (isDirectory(entry)
                    && FileManager.default.fileExists(
                        atPath: entry.appendingPathComponent(
                            StoreLocations.folderMetadataFilename
                        ).path))

            guard isOurs else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func writeBody(_ body: BodySpec, to url: URL) throws {
        let text: String
        switch body {
        case .raw(let contents, _): text = contents
        case .graphQL(let query, _): text = query
        default: return
        }
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    private func writeEnvironments(_ environments: [NibCore.Environment]) throws {
        let directory = root.appendingPathComponent(
            StoreLocations.environmentsDirectoryName, isDirectory: true)

        // Nothing to write and nothing written before: don't create an empty directory in
        // someone's repo just because they opened the app.
        guard !environments.isEmpty || isDirectory(directory) else { return }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Renaming an environment writes a new file; without pruning, the old one stays and the
        // watcher loads both back a moment later, so the rename appears to duplicate instead.
        var expected: Set<String> = []

        for environment in environments {
            // Secrets are stripped here, unconditionally. This is the single most important line in
            // the package: a secret value must never reach a file that gets committed.
            let redacted = NibCore.Environment(
                id: environment.id,
                name: environment.name,
                variables: environment.variables.map { variable in
                    var copy = variable
                    if variable.secret { copy.value = nil }
                    return copy
                }
            )

            let filename =
                "\(Self.sanitise(environment.name)).\(StoreLocations.environmentFileExtension)"
            expected.insert(filename)
            try write(
                DiskFormat.EnvironmentFile(redacted),
                to: directory.appendingPathComponent(filename))
        }

        // Scoped to our own extension, like `removeStaleEntries`. A README or a colleague's
        // notes file living in `environments/` is not ours to delete.
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
            ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix("." + StoreLocations.environmentFileExtension),
                !expected.contains(name)
            else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Drop a `.gitignore` in on first save so `.DS_Store` never lands in someone's commit.
    private func writeGitignoreIfAbsent() throws {
        let url = root.appendingPathComponent(".gitignore")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Data(".DS_Store\n".utf8).write(to: url, options: [.atomic])
    }

    // MARK: - Filenames

    /// Make a display name safe to use as a filename.
    ///
    /// The filename *is* the display name, which is what makes renaming in Finder work — so this has
    /// to be conservative. `/` and `:` are path separators on the two APIs macOS exposes, a leading
    /// dot would hide the file, and an empty name would produce an unopenable file.
    public static func sanitise(_ name: String) -> String {
        var result =
            name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        while result.hasPrefix(".") {
            result.removeFirst()
        }

        return result.isEmpty ? "Untitled" : result
    }

    private static func bodyFilename(for request: RequestNode, sanitisedName: String) -> String? {
        switch request.spec.body {
        case .raw, .graphQL: StoreLocations.bodyFilename(forRequestNamed: sanitisedName)
        default: nil
        }
    }

    // MARK: - Plumbing

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        // Atomic: an interrupted save leaves the previous file, not a truncated one. Blast radius of
        // a failure is a single request.
        try StoreLocations.encodeForDisk(value).write(to: url, options: [.atomic])
    }

    func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    /// Just enough of any of our files to read its version.
    struct FormatVersionProbe: Decodable {
        var formatVersion: Int
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
