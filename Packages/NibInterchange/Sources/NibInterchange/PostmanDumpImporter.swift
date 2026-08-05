import Foundation
import NibCore

/// Postman's bulk "Export Data" archive.
///
/// This is the single biggest lever on the "one drag and your whole workspace comes across" claim: it
/// turns a twenty-collection migration from twenty drags into one. Settings → Account → Export Data
/// emails a zip containing a uniquely-named root folder with `collections/` and `environments/`
/// subfolders, one JSON file per item.
///
/// Unzipping uses `/usr/bin/ditto`, which is on every Mac and needs no dependency — the alternative is
/// hand-rolling a zip reader over `libcompression` for a feature used once per user. Nib is not
/// sandboxed (see docs/signing.md), so there is no exec restriction.
public enum PostmanDumpImporter {

    public struct Imported: Sendable {
        public var collections: [NibCore.Collection]
        public var environments: [NibCore.Environment]
        public var diagnostics: [ImportDiagnostic]
    }

    public static func looksLikePostmanDump(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "zip"
    }

    /// Expand the archive and import everything inside it.
    ///
    /// Deliberately forgiving: a dump can contain files Postman itself wrote and we do not understand,
    /// and one unreadable collection must not sink the other nineteen.
    public static func importDump(at url: URL) throws -> Imported {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-dump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try expand(url, into: staging)

        var collections: [NibCore.Collection] = []
        var environments: [NibCore.Environment] = []
        var diagnostics: [ImportDiagnostic] = []

        // Walk everything rather than assuming the documented layout. The root folder is uniquely
        // named per export, and Postman has changed the structure before.
        let enumerator = FileManager.default.enumerator(
            at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        var jsonFiles: [URL] = []
        while let entry = enumerator?.nextObject() as? URL {
            guard entry.pathExtension.lowercased() == "json" else { continue }
            // `archive.json` is a manifest of exported ids, not content.
            guard entry.lastPathComponent != "archive.json" else { continue }
            jsonFiles.append(entry)
        }

        // Sorted so the import order -- and therefore the resulting file order -- is deterministic
        // rather than dependent on directory enumeration.
        for file in jsonFiles.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: file) else {
                diagnostics.append(
                    ImportDiagnostic(
                        severity: .dropped, path: file.lastPathComponent,
                        message: "Could not read this file from the archive."))
                continue
            }

            if PostmanCollectionImporter.looksLikePostmanCollection(data) {
                do {
                    let imported = try PostmanCollectionImporter.importCollection(data)
                    collections.append(imported.collection)
                    diagnostics.append(contentsOf: imported.diagnostics)
                } catch {
                    diagnostics.append(
                        ImportDiagnostic(
                            severity: .dropped, path: file.lastPathComponent,
                            message: "Skipped: \(Self.message(for: error))"))
                }
                continue
            }

            if PostmanEnvironmentImporter.looksLikePostmanEnvironment(data) {
                do {
                    let imported = try PostmanEnvironmentImporter.importEnvironment(data)
                    environments.append(imported.environment)
                    diagnostics.append(contentsOf: imported.diagnostics)
                } catch {
                    diagnostics.append(
                        ImportDiagnostic(
                            severity: .dropped, path: file.lastPathComponent,
                            message: "Skipped: \(Self.message(for: error))"))
                }
                continue
            }

            // Anything else in the archive is Postman's own metadata. Not worth a diagnostic --
            // reporting every unrecognised file would bury the ones that matter.
        }

        guard !collections.isEmpty || !environments.isEmpty else {
            throw ImportError.malformed(
                reason: "No Postman collections or environments were found in that archive.")
        }

        return Imported(
            collections: collections, environments: environments, diagnostics: diagnostics)
    }

    // MARK: - Unzipping

    public enum DumpError: Error, Sendable, Equatable {
        case expansionFailed(String)
    }

    private static func expand(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -x extract, -k treat the source as a PKZip archive.
        process.arguments = ["-x", "-k", archive.path, directory.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()

        // Read before waiting: a full pipe buffer with nobody draining it deadlocks the child. This is
        // the classic Process mistake and it only shows up on large archives.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail =
                String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DumpError.expansionFailed(
                detail.isEmpty ? "ditto exited with \(process.terminationStatus)" : detail)
        }
    }

    private static func message(for error: any Error) -> String {
        if case ImportError.malformed(let reason) = error { return reason }
        return error.localizedDescription
    }
}
