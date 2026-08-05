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
    /// Held with secret values *populated*, unlike the files on disk. `CollectionStore` strips them
    /// on the way out; see `CollectionModel+Environments.swift` for where they come from.
    public internal(set) var environments: [NibCore.Environment] = []
    public private(set) var rootURL: URL?
    public private(set) var diagnostics: [String] = []
    public private(set) var loadFailure: String?

    /// Selected request. Held by id rather than by value so a reload from disk does not invalidate it.
    public var selectedRequestID: NodeID?

    /// Which environment the picker is on. `nil` means "no environment", which is a real choice and
    /// not an empty state — it is how you check what a request does with only collection defaults.
    public var activeEnvironmentID: NodeID?

    /// Why the Keychain could not be read, if it could not be.
    ///
    /// Load-bearing beyond the message it shows. While this is set, secrets are never written back,
    /// because a Keychain that fails to list looks identical to one holding nothing — and
    /// reconciling against "nothing" would delete every secret the user has.
    public internal(set) var secretsFailure: String?

    /// Bumped on any environment or variable change, so views that depend on resolved values can
    /// observe one small property instead of the whole environment array.
    public internal(set) var environmentsRevision = 0

    /// Whether the editor holds environment edits that have not reached disk yet.
    ///
    /// Guards against a race that is easy to reproduce and very annoying to hit: FSEvents fires
    /// for an unrelated change while the editor is open, `reloadIfChangedExternally` reads the
    /// files, and everything typed since the sheet opened disappears. While this is set, a reload
    /// keeps the in-memory environments and takes only the tree from disk.
    var hasStagedEnvironmentChanges = false

    /// Injectable so tests never touch the service name holding somebody's real tokens.
    let secretStore: SecretStore

    /// Rebuilt when the collection changes, not per keystroke — building 5,000 candidates on every
    /// character typed would undo the point of precomputing them.
    public private(set) var fuzzyCandidates: [FuzzyMatcher.Candidate] = []

    private var store: CollectionStore?
    private var watcher: FolderWatcher?
    /// The generation the store had when we last saved. A watcher callback whose generation matches
    /// is our own write coming back, and reloading then would discard what the user typed next.
    private var lastSavedGeneration = 0

    public init(secretStore: SecretStore = SecretStore()) {
        self.secretStore = secretStore
    }

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
        // Opening a different collection must not inherit the previous one's picker position, or
        // its unsaved edits.
        activeEnvironmentID = nil
        secretsFailure = nil
        hasStagedEnvironmentChanges = false

        do {
            let result = try await store.load()
            apply(result)
            await hydrateSecrets()
            restoreActiveEnvironment()
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
        // Unsaved edits win over the file. The user is looking at them.
        if !hasStagedEnvironmentChanges {
            environments = Self.carryingSecrets(
                from: environments, into: result.environments)
        }
        diagnostics = result.diagnostics
        fuzzyCandidates = result.collection.fuzzyCandidates()

        // Keep the selection if the request still exists; otherwise fall back to the first one, so
        // the pane is never left showing a request that has been deleted on disk.
        if let selectedRequestID, result.collection.request(withID: selectedRequestID) != nil {
            return
        }
        selectedRequestID = result.collection.allRequests.first?.request.id
    }

    /// Keep secret values we already hold when re-reading the files.
    ///
    /// A reload publishes what is on disk, and on disk every secret is `null`. `hydrateSecrets`
    /// puts the values back, but it is `async` — so without this there is a window, one suspension
    /// point wide, where every token in the app reads as empty. Anything that samples the model in
    /// that window (a view redrawing, a save triggered by an unrelated edit) sees blanks and can
    /// write them back.
    ///
    /// Matched on environment name plus key rather than on `NodeID`, because that pair is what the
    /// Keychain account is built from and therefore what identity means for a secret.
    private static func carryingSecrets(
        from existing: [NibCore.Environment],
        into incoming: [NibCore.Environment]
    ) -> [NibCore.Environment] {
        var held: [String: String] = [:]
        for environment in existing {
            for variable in environment.variables where variable.secret {
                if let value = variable.value {
                    held["\(environment.name)/\(variable.key)"] = value
                }
            }
        }
        guard !held.isEmpty else { return incoming }

        return incoming.map { environment in
            var environment = environment
            for index in environment.variables.indices
            where environment.variables[index].secret && environment.variables[index].value == nil {
                environment.variables[index].value =
                    held["\(environment.name)/\(environment.variables[index].key)"]
            }
            return environment
        }
    }

    public func close() {
        watcher?.stop()
        watcher = nil
        store = nil
        collection = nil
        environments = []
        activeEnvironmentID = nil
        secretsFailure = nil
        hasStagedEnvironmentChanges = false
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
            let result = try await store.load()

            // Re-check before publishing. Reading the folder takes long enough for a save to
            // finish underneath us, and this snapshot was taken *before* that write — applying it
            // would roll the model back to the state the files were in a moment ago and then
            // persist that on the next save. The symptom is an edit that vanishes seconds after
            // being made, which is close to impossible to reproduce deliberately.
            guard await store.currentWriteGeneration == generation else { return }

            apply(result)
            // The file on disk has `null` where a secret is, so re-reading it would blank values
            // the user has already entered. Put them back.
            await hydrateSecrets()
            restoreActiveEnvironment()
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
        await synchroniseSecrets()
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
        environments.sort { $0.name < $1.name }
        environmentsRevision += 1
        // An import is usually the first environment a collection has, so point the picker at it
        // rather than making the user find it.
        restoreActiveEnvironment()
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

    /// The variable scope for a request: collection defaults, then folder, then the active
    /// environment. Precedence itself lives in `VariableScope` and is tested there.
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

        if let environment = activeEnvironment {
            scope.set(Self.dictionary(environment.variables), for: .environment)
        }

        return scope
    }

    public func inheritedAuth(forRequestWithID id: NodeID) -> AuthSpec {
        guard let collection,
            let entry = collection.allRequests.first(where: { $0.request.id == id })
        else { return .none }
        return collection.inheritedAuth(forRequestAt: entry.path)
    }

    /// Disabled variables and secrets with no stored value both drop out here.
    ///
    /// The second case is the one that matters: on a freshly cloned repo the Keychain holds
    /// nothing, so `{{TOKEN}}` reports as unresolved and stays visible in the URL. Substituting an
    /// empty string instead would send a request with a blank credential and a confusing 401.
    static func dictionary(_ variables: [EnvironmentVariable]) -> [String: String] {
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
