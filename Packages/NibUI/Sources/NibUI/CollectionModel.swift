import AppKit
import Foundation
import NibCore
import NibStore
import Observation

/// The open collection, its selection, and the disk plumbing behind them.
///
/// Owns the store and the watcher so `AppModel` stays about the app rather than about files.
@Observable
// The length limit exists to catch a type that has grown too many responsibilities. This one has
// exactly one -- the open collection and everything that reads or writes it. Splitting it across
// files was tried and fought `private`/`private(set)` on the observable state, which is
// encapsulation worth more than a line count.
// swiftlint:disable:next type_body_length
public final class CollectionModel {

    public private(set) var collection: NibCore.Collection?
    public private(set) var environments: [NibCore.Environment] = []
    public private(set) var rootURL: URL?
    public private(set) var diagnostics: [String] = []
    public private(set) var loadFailure: String?

    /// Selected request. Held by id rather than by value so a reload from disk does not invalidate it.
    public var selectedRequestID: NodeID?

    /// Rebuilt when the collection changes, not per keystroke — building 5,000 candidates on every
    /// character typed would undo the point of precomputing them.
    public private(set) var fuzzyCandidates: [FuzzyMatcher.Candidate] = []

    private var store: CollectionStore?
    private var watcher: FolderWatcher?
    /// The generation the store had when we last saved. A watcher callback whose generation matches
    /// is our own write coming back, and reloading then would discard what the user typed next.
    private var lastSavedGeneration = 0

    public init() {}

    public var isOpen: Bool { collection != nil }

    // MARK: - Opening

    /// Ask for a folder and open it.
    ///
    /// An empty folder is offered as a new collection rather than refused: "open a folder" and "start
    /// a collection here" are the same gesture from the user's point of view.
    public func promptToOpen() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder for your collection. Nib keeps one file per request."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        await open(url)
    }

    public func open(_ url: URL) async {
        let store = CollectionStore(root: url)
        self.store = store
        rootURL = url
        loadFailure = nil

        do {
            let result = try await store.load()
            apply(result)
        } catch let error as CollectionStore.StoreError {
            switch error {
            case .missingCollectionFile:
                // Not an error: this is how a new collection begins.
                await createCollection(named: url.lastPathComponent, in: store)
            case .notADirectory(let path):
                loadFailure = "\(path) is not a folder."
            case .unsupportedFormatVersion(let version):
                loadFailure =
                    "This collection was written by a newer version of Nib (format \(version)). "
                    + "Update Nib to open it."
            }
        } catch {
            loadFailure = error.localizedDescription
        }

        startWatching(url)
        rememberRecent(url)
    }

    private func createCollection(named name: String, in store: CollectionStore) async {
        let fresh = NibCore.Collection(name: name)
        do {
            try await store.save(fresh)
            lastSavedGeneration = await store.currentWriteGeneration
            apply(
                CollectionStore.LoadResult(
                    collection: fresh, environments: [], diagnostics: []))
        } catch {
            loadFailure = "Could not create a collection here: \(error.localizedDescription)"
        }
    }

    private func apply(_ result: CollectionStore.LoadResult) {
        collection = result.collection
        environments = result.environments
        diagnostics = result.diagnostics
        fuzzyCandidates = result.collection.fuzzyCandidates()

        // Keep the selection if the request still exists; otherwise fall back to the first one, so
        // the pane is never left showing a request that has been deleted on disk.
        if let selectedRequestID, result.collection.request(withID: selectedRequestID) != nil {
            return
        }
        selectedRequestID = result.collection.allRequests.first?.request.id
    }

    public func close() {
        watcher?.stop()
        watcher = nil
        store = nil
        collection = nil
        environments = []
        rootURL = nil
        selectedRequestID = nil
        fuzzyCandidates = []
        diagnostics = []
    }

    // MARK: - Watching

    private func startWatching(_ url: URL) {
        watcher?.stop()
        watcher = FolderWatcher(root: url) { [weak self] in
            // FSEvents delivers on its own queue; hop to the main actor to touch observable state.
            Task { @MainActor [weak self] in
                await self?.reloadIfChangedExternally()
            }
        }
        watcher?.start()
    }

    /// Reload, unless the change was ours.
    private func reloadIfChangedExternally() async {
        guard let store else { return }

        let generation = await store.currentWriteGeneration
        guard generation == lastSavedGeneration else {
            // Our own write coming back. Catch up and ignore it.
            lastSavedGeneration = generation
            return
        }

        do {
            apply(try await store.load())
        } catch {
            // A transient failure here is normal: an editor writing a file in two steps can be
            // observed mid-write. Keep what we have rather than blanking the sidebar.
            diagnostics = ["Reload skipped: \(error.localizedDescription)"]
        }
    }

    // MARK: - Editing

    public func save() async {
        guard let store, let collection else { return }
        do {
            try await store.save(collection, environments: environments)
            lastSavedGeneration = await store.currentWriteGeneration
        } catch {
            diagnostics = ["Could not save: \(error.localizedDescription)"]
        }
    }

    /// Write an edited request back into the tree and save.
    public func update(_ request: RequestNode) async {
        guard var collection else { return }
        collection.children = Self.replacing(request, in: collection.children)
        self.collection = collection
        fuzzyCandidates = collection.fuzzyCandidates()
        await save()
    }

    private static func replacing(
        _ request: RequestNode,
        in nodes: [CollectionNode]
    ) -> [CollectionNode] {
        nodes.map { node in
            switch node {
            case .request(let existing):
                return existing.id == request.id ? .request(request) : node
            case .folder(var folder):
                folder.children = replacing(request, in: folder.children)
                return .folder(folder)
            }
        }
    }

    /// Merge imported collections and environments into the open one.
    ///
    /// Each imported collection becomes a folder rather than replacing the tree: someone importing a
    /// second Postman workspace into an existing collection expects it added, not swapped. A single
    /// imported collection whose name matches the open one is merged at the top level instead, since
    /// nesting "Acme API" inside "Acme API" is noise.
    public func merge(
        collections: [NibCore.Collection],
        environments incoming: [NibCore.Environment]
    ) async {
        guard var collection else { return }

        for imported in collections {
            if collections.count == 1, imported.name == collection.name {
                collection.children.append(contentsOf: imported.children)
                collection.variables = Self.mergedVariables(
                    collection.variables, imported.variables)
                if collection.auth == .none { collection.auth = imported.auth }
            } else {
                collection.children.append(
                    .folder(
                        FolderNode(
                            name: Self.uniqueName(imported.name, among: collection.children),
                            children: imported.children,
                            auth: imported.auth,
                            variables: imported.variables)))
            }
        }

        for environment in incoming {
            if let index = environments.firstIndex(where: { $0.name == environment.name }) {
                environments[index].variables = Self.mergedVariables(
                    environments[index].variables, environment.variables)
            } else {
                environments.append(environment)
            }
        }

        self.collection = collection
        fuzzyCandidates = collection.fuzzyCandidates()
        if selectedRequestID == nil {
            selectedRequestID = collection.allRequests.first?.request.id
        }
        await save()
    }

    /// Existing values win. An import should not silently overwrite a value someone has already tuned.
    private static func mergedVariables(
        _ existing: [EnvironmentVariable],
        _ incoming: [EnvironmentVariable]
    ) -> [EnvironmentVariable] {
        var result = existing
        let known = Set(existing.map(\.key))
        result.append(contentsOf: incoming.filter { !known.contains($0.key) })
        return result
    }

    private static func uniqueName(_ name: String, among nodes: [CollectionNode]) -> String {
        let taken = Set(nodes.map(\.name))
        guard taken.contains(name) else { return name }
        var suffix = 2
        while taken.contains("\(name) \(suffix)") { suffix += 1 }
        return "\(name) \(suffix)"
    }

    public func addRequest(named name: String = "New request") async {
        guard var collection else { return }
        let request = RequestNode(name: name, spec: HTTPRequestSpec(url: ""))
        collection.children.append(.request(request))
        self.collection = collection
        selectedRequestID = request.id
        fuzzyCandidates = collection.fuzzyCandidates()
        await save()
    }

    public func addFolder(named name: String = "New folder") async {
        guard var collection else { return }
        collection.children.append(.folder(FolderNode(name: name)))
        self.collection = collection
        await save()
    }

    public func delete(_ id: NodeID) async {
        guard var collection else { return }
        collection.children = Self.removing(id, from: collection.children)
        self.collection = collection
        fuzzyCandidates = collection.fuzzyCandidates()
        if selectedRequestID == id {
            selectedRequestID = collection.allRequests.first?.request.id
        }
        await save()
    }

    private static func removing(_ id: NodeID, from nodes: [CollectionNode]) -> [CollectionNode] {
        nodes.compactMap { node in
            guard node.id != id else { return nil }
            if case .folder(var folder) = node {
                folder.children = removing(id, from: folder.children)
                return .folder(folder)
            }
            return node
        }
    }

    public func rename(_ id: NodeID, to name: String) async {
        guard var collection else { return }
        collection.children = Self.renaming(id, to: name, in: collection.children)
        self.collection = collection
        fuzzyCandidates = collection.fuzzyCandidates()
        await save()
    }

    private static func renaming(
        _ id: NodeID,
        to name: String,
        in nodes: [CollectionNode]
    ) -> [CollectionNode] {
        nodes.map { node in
            switch node {
            case .request(var request):
                if request.id == id { request.name = name }
                return .request(request)
            case .folder(var folder):
                if folder.id == id { folder.name = name }
                folder.children = renaming(id, to: name, in: folder.children)
                return .folder(folder)
            }
        }
    }

    // MARK: - Lookup

    public var selectedRequest: RequestNode? {
        guard let selectedRequestID else { return nil }
        return collection?.request(withID: selectedRequestID)
    }

    /// The variable scope for a request: collection defaults, then folder, then the request itself.
    ///
    /// Environment layering lands in Phase 5; this wires up the layers that exist on disk today.
    public func scope(forRequestWithID id: NodeID) -> VariableScope {
        var scope = VariableScope()
        guard let collection,
            let entry = collection.allRequests.first(where: { $0.request.id == id })
        else { return scope }

        scope.set(Self.dictionary(collection.variables), for: .collection)

        // Innermost folder last, so it overwrites outer folders.
        var folderValues: [String: String] = [:]
        for folder in entry.path {
            folderValues.merge(Self.dictionary(folder.variables)) { _, inner in inner }
        }
        scope.set(folderValues, for: .folder)

        return scope
    }

    public func inheritedAuth(forRequestWithID id: NodeID) -> AuthSpec {
        guard let collection,
            let entry = collection.allRequests.first(where: { $0.request.id == id })
        else { return .none }
        return collection.inheritedAuth(forRequestAt: entry.path)
    }

    private static func dictionary(_ variables: [EnvironmentVariable]) -> [String: String] {
        variables.reduce(into: [:]) { result, variable in
            guard variable.enabled, let value = variable.value else { return }
            result[variable.key] = value
        }
    }

    // MARK: - Recents

    static let recentsKey = "RecentCollections"

    private func rememberRecent(_ url: URL) {
        var recents = Self.recentCollections()
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        UserDefaults.standard.set(
            recents.prefix(8).map(\.path), forKey: Self.recentsKey)
    }

    public static func recentCollections() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
