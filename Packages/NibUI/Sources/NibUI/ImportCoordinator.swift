import AppKit
import Foundation
import NibCore
import NibInterchange
import Observation

/// Everything about getting someone else's collection into Nib.
///
/// One entry point that sniffs the file rather than several menu items for several formats: the user
/// has "an export", not "a v2.1 collection JSON", and making them classify it first is a worse
/// experience than looking at the bytes.
@Observable
public final class ImportCoordinator {

    public struct Report: Sendable, Identifiable {
        public let id = UUID()
        public var collectionNames: [String]
        public var environmentNames: [String]
        public var requestCount: Int
        public var diagnostics: [ImportDiagnostic]

        public var isClean: Bool { diagnostics.isEmpty }
    }

    public private(set) var report: Report?
    public private(set) var failure: String?
    public private(set) var isImporting = false

    private let collectionModel: CollectionModel

    public init(collectionModel: CollectionModel) {
        self.collectionModel = collectionModel
    }

    public func dismissReport() {
        report = nil
        failure = nil
    }

    /// Explain a drop that contained nothing we could read.
    public func reportUnsupportedDrop(_ names: [String]) {
        guard !names.isEmpty else { return }
        let subject =
            names.count == 1
            ? "“\(names[0])” is not something Nib can import."
            : "Those \(names.count) files are not something Nib can import."
        failure =
            subject + "\n\nDrop a Postman collection or environment (.json), an “Export Data” "
            + "archive (.zip), or the folder you unzipped one to."
    }

    // MARK: - Entry points

    public func promptToImport() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // Folders are selectable for the same reason `canImport` accepts them: an unzipped export is
        // a folder, and greying it out is indistinguishable from the app being broken.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message =
            "Choose a Postman collection, an environment, or an “Export Data” archive — "
            + "either the .zip or the folder you unzipped it to."
        // No `allowedContentTypes`: it greys out everything it does not list, and a greyed-out file
        // gives the user nothing to act on. Sniffing the bytes and saying what was wrong is better
        // than a panel that silently refuses to let them click.
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        await importFiles(panel.urls)
    }

    /// Import one or more dropped or chosen files.
    ///
    /// Aggregated into a single report: dropping four files and getting four sheets in a row would be
    /// worse than one summary.
    public func importFiles(_ urls: [URL]) async {
        guard collectionModel.isOpen else {
            failure = "Open a collection folder first — Nib imports into a folder you choose."
            return
        }

        isImporting = true
        defer { isImporting = false }

        var collections: [NibCore.Collection] = []
        var environments: [NibCore.Environment] = []
        var diagnostics: [ImportDiagnostic] = []
        var failures: [String] = []

        for url in urls {
            do {
                let outcome = try Self.read(url)
                collections.append(contentsOf: outcome.collections)
                environments.append(contentsOf: outcome.environments)
                diagnostics.append(contentsOf: outcome.diagnostics)
            } catch {
                failures.append("\(url.lastPathComponent): \(Self.describe(error))")
            }
        }

        guard !collections.isEmpty || !environments.isEmpty else {
            failure =
                failures.isEmpty
                ? "Nothing importable was found in those files."
                : failures.joined(separator: "\n")
            return
        }

        if !failures.isEmpty {
            diagnostics.append(
                contentsOf: failures.map {
                    ImportDiagnostic(severity: .dropped, path: "file", message: $0)
                })
        }

        await collectionModel.merge(collections: collections, environments: environments)

        report = Report(
            collectionNames: collections.map(\.name),
            environmentNames: environments.map(\.name),
            requestCount: collections.reduce(0) { $0 + $1.allRequests.count },
            diagnostics: diagnostics
        )
    }

    /// Whether a dragged file is something we would try to import.
    ///
    /// Used to decide whether to accept the drag at all, so the cursor tells the truth before the drop.
    ///
    /// Folders count. A Postman "Export Data" archive arrives as a zip, and a Mac set to open safe
    /// downloads unzips it before the user ever sees it — refusing the folder meant the most common
    /// shape of the most important import silently did nothing.
    public static func canImport(_ url: URL) -> Bool {
        if isDirectory(url) { return true }
        let extensionName = url.pathExtension.lowercased()
        return extensionName == "json" || extensionName == "zip"
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - Reading

    private struct Outcome {
        var collections: [NibCore.Collection] = []
        var environments: [NibCore.Environment] = []
        var diagnostics: [ImportDiagnostic] = []
    }

    /// Sniff and dispatch. The order matters: a zip cannot be sniffed as JSON, and an environment must
    /// be checked against the collection sniffer first so the two never overlap.
    private static func read(_ url: URL) throws -> Outcome {
        if isDirectory(url) {
            let imported = try PostmanDumpImporter.importExpanded(at: url)
            return Outcome(
                collections: imported.collections,
                environments: imported.environments,
                diagnostics: imported.diagnostics)
        }

        if PostmanDumpImporter.looksLikePostmanDump(url) {
            let imported = try PostmanDumpImporter.importDump(at: url)
            return Outcome(
                collections: imported.collections,
                environments: imported.environments,
                diagnostics: imported.diagnostics)
        }

        let data = try Data(contentsOf: url)

        if PostmanCollectionImporter.looksLikePostmanCollection(data) {
            let imported = try PostmanCollectionImporter.importCollection(data)
            return Outcome(collections: [imported.collection], diagnostics: imported.diagnostics)
        }

        if PostmanEnvironmentImporter.looksLikePostmanEnvironment(data) {
            let imported = try PostmanEnvironmentImporter.importEnvironment(data)
            return Outcome(environments: [imported.environment], diagnostics: imported.diagnostics)
        }

        if CurlImporter.looksLikeCurl(String(data: data, encoding: .utf8) ?? "") {
            let parsed = try CurlImporter.parse(String(data: data, encoding: .utf8) ?? "")
            let name = url.deletingPathExtension().lastPathComponent
            return Outcome(
                collections: [
                    NibCore.Collection(
                        name: name,
                        children: [.request(RequestNode(name: name, spec: parsed.spec))])
                ],
                diagnostics: parsed.diagnostics)
        }

        throw ImportError.unrecognisedFormat
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case ImportError.unrecognisedFormat:
            "Not a Postman collection, environment, archive or cURL command."
        case ImportError.malformed(let reason):
            reason
        case ImportError.unsupportedVersion(let version):
            "Unsupported format version \(version)."
        case PostmanDumpImporter.DumpError.expansionFailed(let detail):
            "Could not open the archive: \(detail)"
        default:
            error.localizedDescription
        }
    }
}
