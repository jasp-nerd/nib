import Foundation
import NibCore
import Testing

@testable import NibInterchange

/// The bulk "Export Data" archive — the path that turns a twenty-collection migration into one drag.
///
/// Builds a real zip with `ditto` rather than checking a binary fixture into git, so the test exercises
/// the same expansion code on the same tool the app uses.
@Suite("Postman data dump", .serialized)
struct PostmanDumpTests {

    /// Assemble an archive shaped like a real export: a uniquely-named root, `collections/` and
    /// `environments/` subfolders, plus the `archive.json` manifest Postman includes.
    private func makeDump(
        collections: [String],
        environments: [String],
        extras: [String: String] = [:]
    ) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-dump-src-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent("Backup.2026-08-05", isDirectory: true)
        let collectionsDirectory = root.appendingPathComponent("collections", isDirectory: true)
        let environmentsDirectory = root.appendingPathComponent("environments", isDirectory: true)

        try FileManager.default.createDirectory(
            at: collectionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: environmentsDirectory, withIntermediateDirectories: true)

        let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("postman")

        for name in collections {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name),
                to: collectionsDirectory.appendingPathComponent(name))
        }
        for name in environments {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name),
                to: environmentsDirectory.appendingPathComponent(name))
        }

        // Postman's manifest of exported ids. Must be ignored, not parsed as content.
        try Data(#"{"collection":[],"environment":[]}"#.utf8).write(
            to: root.appendingPathComponent("archive.json"))

        for (name, contents) in extras {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }

        let archive = staging.appendingPathComponent("dump.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", root.path, archive.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        return archive
    }

    @Test("one drag brings several collections and environments across")
    func importsWholeWorkspace() throws {
        let archive = try makeDump(
            collections: [
                "typical.postman_collection.json",
                "legacy-v2.postman_collection.json",
            ],
            environments: [
                "staging.postman_environment.json",
                "globals.postman_globals.json",
            ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let result = try PostmanDumpImporter.importDump(at: archive)

        #expect(result.collections.count == 2)
        #expect(result.collections.map(\.name).sorted() == ["Acme API", "Legacy"])
        #expect(result.environments.count == 2)
        #expect(result.environments.map(\.name).sorted() == ["Globals", "Staging"])

        // Diagnostics from every file are aggregated, so the report covers the whole import.
        #expect(result.diagnostics.contains { $0.message.contains("script") })
    }

    @Test("archive.json and unknown files are ignored without noise")
    func ignoresManifestAndStrays() throws {
        let archive = try makeDump(
            collections: ["legacy-v2.postman_collection.json"],
            environments: [],
            extras: ["notes.txt": "hello", "weird.json": #"{"unrelated":true}"#])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let result = try PostmanDumpImporter.importDump(at: archive)

        #expect(result.collections.count == 1)
        // Reporting every unrecognised file would bury the diagnostics that matter.
        #expect(!result.diagnostics.contains { $0.message.contains("weird.json") })
        #expect(!result.diagnostics.contains { $0.message.contains("archive.json") })
    }

    @Test("one unreadable collection does not sink the rest")
    func toleratesOneBadFile() throws {
        let archive = try makeDump(
            collections: ["typical.postman_collection.json"],
            environments: [],
            extras: [
                // Looks like a collection to the sniffer, but will not decode.
                "broken.postman_collection.json":
                    #"{"info":{"name":"Broken","schema":"x/collection/v2.1.0/collection.json"}}"#
            ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let result = try PostmanDumpImporter.importDump(at: archive)

        #expect(result.collections.map(\.name) == ["Acme API"])
        #expect(
            result.diagnostics.contains {
                $0.severity == .dropped && $0.path.contains("broken")
            })
    }

    @Test("an archive with nothing importable is an error, not a silent success")
    func emptyArchiveIsAnError() throws {
        let archive = try makeDump(
            collections: [], environments: [], extras: ["readme.txt": "nothing here"])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        #expect(throws: ImportError.self) {
            _ = try PostmanDumpImporter.importDump(at: archive)
        }
    }

    @Test("a file that is not a zip fails with a readable message")
    func notAZip() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-zip-\(UUID().uuidString).zip")
        try Data("just text".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }

        #expect(throws: (any Error).self) {
            _ = try PostmanDumpImporter.importDump(at: fake)
        }
    }

    @Test("import order is deterministic, so the resulting files are too")
    func deterministicOrder() throws {
        let archive = try makeDump(
            collections: [
                "typical.postman_collection.json",
                "legacy-v2.postman_collection.json",
                "polymorphic.postman_collection.json",
            ],
            environments: [])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        let first = try PostmanDumpImporter.importDump(at: archive).collections.map(\.name)
        let second = try PostmanDumpImporter.importDump(at: archive).collections.map(\.name)
        #expect(first == second)
    }

    // MARK: - Already unzipped

    /// The export arrives by email as a zip, and a Mac set to open safe downloads expands it before
    /// the user ever sees the archive. Handing Nib that folder has to work: refusing it stops the
    /// migration at step one for everyone with the default Safari setting.
    @Test("an export that has already been unzipped imports from the folder")
    func importsExpandedFolder() throws {
        let archive = try makeDump(
            collections: [
                "typical.postman_collection.json",
                "legacy-v2.postman_collection.json",
            ],
            environments: ["staging.postman_environment.json"])
        let staging = archive.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: staging) }

        let root = staging.appendingPathComponent("Backup.2026-08-05", isDirectory: true)
        let result = try PostmanDumpImporter.importExpanded(at: root)

        #expect(result.collections.map(\.name).sorted() == ["Acme API", "Legacy"])
        #expect(result.environments.map(\.name) == ["Staging"])
    }

    /// The zip and the folder are the same content, so they must produce the same result. If they
    /// ever diverge it will be because one path grew a fix the other did not.
    @Test("the folder and the zip it came from import identically")
    func expandedMatchesArchive() throws {
        let archive = try makeDump(
            collections: ["typical.postman_collection.json"],
            environments: ["staging.postman_environment.json"])
        let staging = archive.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: staging) }

        let fromArchive = try PostmanDumpImporter.importDump(at: archive)
        let fromFolder = try PostmanDumpImporter.importExpanded(
            at: staging.appendingPathComponent("Backup.2026-08-05", isDirectory: true))

        #expect(fromArchive.collections.map(\.name) == fromFolder.collections.map(\.name))
        #expect(fromArchive.environments.map(\.name) == fromFolder.environments.map(\.name))
        #expect(
            fromArchive.collections.map(\.allRequests.count)
                == fromFolder.collections.map(\.allRequests.count))
    }

    @Test("a folder with nothing importable in it says so rather than throwing something opaque")
    func emptyFolderIsReadable() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(throws: ImportError.self) {
            _ = try PostmanDumpImporter.importExpanded(at: empty)
        }
    }
}
