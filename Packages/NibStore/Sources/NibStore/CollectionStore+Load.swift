import Foundation
import NibCore

// Loading, split out from the writing side.
//
// Reading is where all the tolerance lives -- unknown files ignored, malformed requests skipped with
// a diagnostic, `order` reconciled against what is actually on disk -- and writing is where all the
// determinism lives. They share a type but almost no code, so they get a file each.

extension CollectionStore {

    // MARK: - Loading

    /// Load the whole collection.
    ///
    /// Tolerant on purpose. A folder someone has been editing by hand, or that a colleague added a
    /// file to, must still open: unknown files are ignored, a request that fails to parse is skipped
    /// with a diagnostic rather than aborting the load, and missing `order` entries are appended
    /// alphabetically.
    public func load() throws -> LoadResult {
        var diagnostics: [String] = []

        guard isDirectory(root) else { throw StoreError.notADirectory(root.path) }

        let metadataURL = root.appendingPathComponent(StoreLocations.collectionMetadataFilename)
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw StoreError.missingCollectionFile(metadataURL.path)
        }

        // Check the version before decoding the body of the file. A future format would otherwise
        // fail with an opaque DecodingError about whichever field changed shape first, instead of
        // saying plainly that the file is too new.
        let data = try Data(contentsOf: metadataURL)
        let version = try JSONDecoder().decode(FormatVersionProbe.self, from: data).formatVersion
        guard version <= StoreLocations.formatVersion else {
            throw StoreError.unsupportedFormatVersion(version)
        }

        let file = try JSONDecoder().decode(DiskFormat.CollectionFile.self, from: data)

        let children = try loadChildren(in: root, order: file.order, diagnostics: &diagnostics)
        let environments = try loadEnvironments(diagnostics: &diagnostics)

        let collection = NibCore.Collection(
            id: NodeID(rawValue: file.id),
            name: file.name,
            children: children,
            auth: file.auth,
            variables: file.variables
        )

        return LoadResult(
            collection: collection, environments: environments, diagnostics: diagnostics)
    }

    func loadChildren(
        in directory: URL,
        order: [String],
        diagnostics: inout [String]
    ) throws -> [CollectionNode] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        var byName: [String: CollectionNode] = [:]

        for entry in entries {
            if isDirectory(entry) {
                // A directory without folder.json is not ours -- someone's scratch folder, a
                // .git checkout. Skip it silently rather than adopting it.
                let marker = entry.appendingPathComponent(StoreLocations.folderMetadataFilename)
                guard FileManager.default.fileExists(atPath: marker.path) else { continue }
                if let folder = try? loadFolder(at: entry, diagnostics: &diagnostics) {
                    byName[folder.name] = .folder(folder)
                }
                continue
            }

            guard entry.lastPathComponent.hasSuffix("." + StoreLocations.requestFileExtension)
            else {
                continue
            }

            let name = String(
                entry.lastPathComponent.dropLast(StoreLocations.requestFileExtension.count + 1))
            do {
                let request = try loadRequest(at: entry, name: name)
                byName[name] = .request(request)
            } catch {
                // One malformed file must not stop the other 200 from opening.
                diagnostics.append(
                    "Skipped \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return reconcile(order: order, with: byName)
    }

    /// Apply the recorded order, then append anything new alphabetically.
    ///
    /// The append is what makes `cp` from Finder work: a file that appears on disk shows up in the
    /// sidebar without the user having to know `order` exists.
    func reconcile(
        order: [String],
        with byName: [String: CollectionNode]
    ) -> [CollectionNode] {
        var result: [CollectionNode] = []
        var remaining = byName

        for name in order {
            if let node = remaining.removeValue(forKey: name) {
                result.append(node)
            }
        }

        result.append(contentsOf: remaining.values.sorted { $0.name < $1.name })
        return result
    }

    func loadFolder(at directory: URL, diagnostics: inout [String]) throws -> FolderNode {
        let metadataURL = directory.appendingPathComponent(StoreLocations.folderMetadataFilename)
        let file = try decode(DiskFormat.FolderFile.self, from: metadataURL)
        let children = try loadChildren(in: directory, order: file.order, diagnostics: &diagnostics)

        return FolderNode(
            id: NodeID(rawValue: file.id),
            name: directory.lastPathComponent,
            children: children,
            auth: file.auth,
            variables: file.variables
        )
    }

    func loadRequest(at url: URL, name: String) throws -> RequestNode {
        let file = try decode(DiskFormat.RequestFile.self, from: url)

        // The body's sibling file, if the format says there is one.
        var contents: String?
        if let filename = file.body.file, file.body.type != "binary" {
            let bodyURL = url.deletingLastPathComponent().appendingPathComponent(filename)
            contents = try? String(contentsOf: bodyURL, encoding: .utf8)
        }

        let spec = HTTPRequestSpec(
            method: HTTPMethod(file.method),
            url: file.url,
            params: file.params,
            headers: file.headers,
            body: file.body.body(withContents: contents),
            auth: file.auth,
            settings: file.settings
        )

        return RequestNode(id: NodeID(rawValue: file.id), name: name, spec: spec)
    }

    func loadEnvironments(diagnostics: inout [String]) throws -> [NibCore.Environment] {
        let directory = root.appendingPathComponent(StoreLocations.environmentsDirectoryName)
        guard isDirectory(directory) else { return [] }

        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
            ?? []

        var environments: [NibCore.Environment] = []
        for entry in entries
        where entry.lastPathComponent.hasSuffix("." + StoreLocations.environmentFileExtension) {
            do {
                let file = try decode(DiskFormat.EnvironmentFile.self, from: entry)
                environments.append(
                    NibCore.Environment(
                        id: NodeID(rawValue: file.id),
                        name: file.name,
                        variables: file.variables))
            } catch {
                diagnostics.append(
                    "Skipped environment \(entry.lastPathComponent): "
                        + error.localizedDescription)
            }
        }

        return environments.sorted { $0.name < $1.name }
    }

}
