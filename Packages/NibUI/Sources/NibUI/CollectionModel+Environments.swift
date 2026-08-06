import Foundation
import NibCore
import NibStore

/// Environments, and the Keychain traffic behind them.
///
/// Split out of `CollectionModel` rather than nested in it because this is the one part of the
/// model with a second backing store, and it is worth being able to read the secret handling in
/// one screen. The stored properties it works on stay in the main file, where the `@Observable`
/// macro can see them.
///
/// The shape of the whole thing: files hold the keys, the Keychain holds the values, and memory
/// holds both. Everything below exists to keep those three in step without ever letting a value
/// travel into store 1.
extension CollectionModel {

    public var activeEnvironment: NibCore.Environment? {
        guard let activeEnvironmentID else { return nil }
        return environments.first { $0.id == activeEnvironmentID }
    }

    // MARK: - Selecting

    /// Switch environment and re-resolve. The whole point of Phase 5 in one method.
    public func setActiveEnvironment(_ id: NodeID?) {
        activeEnvironmentID = id
        environmentsRevision += 1
        persistActiveEnvironment()
    }

    /// Restore the picker's position for this collection, dropping a stale id.
    ///
    /// An environment can vanish between sessions — deleted on another machine, or the branch
    /// changed underneath us. Leaving the id pointing at nothing would silently resolve every
    /// `{{var}}` against collection defaults while the picker still showed a name.
    func restoreActiveEnvironment() {
        guard let collection else { return }

        if let activeEnvironmentID, environments.contains(where: { $0.id == activeEnvironmentID }) {
            return
        }

        let remembered =
            UserDefaults.standard
            .dictionary(forKey: Self.activeEnvironmentKey)?[collection.id.rawValue] as? String

        activeEnvironmentID =
            environments.first { $0.id.rawValue == remembered }?.id
            ?? environments.first?.id

        // Re-resolve, exactly as `setActiveEnvironment` does. Picking the environment during load
        // happens *after* the selection has already computed its scope, so without this the first
        // request you look at resolves against nothing: the picker says "Local", the badge says
        // two variables, and the URL bar still says {{baseUrl}} is not defined. Sending then fails
        // with "That URL could not be parsed" until you switch to another request and back.
        if activeEnvironmentID != nil {
            environmentsRevision += 1
        }
    }

    static var activeEnvironmentKey: String { "ActiveEnvironment" }

    private func persistActiveEnvironment() {
        guard let collection else { return }
        // App state, so `UserDefaults` — store 2. Writing the active environment into the
        // collection folder would put one developer's choice in everybody's diff.
        var stored =
            UserDefaults.standard.dictionary(forKey: Self.activeEnvironmentKey) ?? [:]
        stored[collection.id.rawValue] = activeEnvironmentID?.rawValue
        UserDefaults.standard.set(stored, forKey: Self.activeEnvironmentKey)
    }

    // MARK: - Editing
    //
    // Every mutation here is staged in memory and written by `commitEnvironments`, which the
    // editor calls once when it closes. Saving per keystroke would mean a file write and a
    // Keychain write for every character typed into a token — and a rename would produce a fresh
    // Keychain account per character along the way.
    //
    // The in-memory half is deliberately immediate: `{{baseUrl}}` in the URL bar resolves as you
    // type the value, which is the thing that makes the editor feel like part of the app rather
    // than a settings dialog.

    @discardableResult
    public func stageAddEnvironment(named name: String = "New environment") -> NodeID {
        let environment = NibCore.Environment(
            name: Self.uniqueEnvironmentName(name, among: environments))
        environments.append(environment)
        markEnvironmentsStaged()
        setActiveEnvironment(environment.id)
        return environment.id
    }

    public func stageDeleteEnvironment(_ id: NodeID) {
        environments.removeAll { $0.id == id }
        markEnvironmentsStaged()
        if activeEnvironmentID == id {
            setActiveEnvironment(environments.first?.id)
        }
    }

    /// Replace one environment wholesale, renames included.
    ///
    /// Note what this does *not* do: reorder. The list is sorted by name everywhere else, but
    /// sorting mid-rename would slide the row out from under the cursor on the first keystroke.
    /// `commitEnvironments` sorts.
    public func stage(_ environment: NibCore.Environment) {
        guard let index = environments.firstIndex(where: { $0.id == environment.id }) else {
            return
        }
        environments[index] = environment
        markEnvironmentsStaged()
    }

    private func markEnvironmentsStaged() {
        hasStagedEnvironmentChanges = true
        environmentsRevision += 1
    }

    /// Write staged changes to the files and the Keychain.
    ///
    /// Names are settled here rather than during editing: a rename that collides only becomes a
    /// problem when it reaches the filesystem, where two environments cannot share a filename.
    public func commitEnvironments() async {
        for index in environments.indices {
            let others = environments.enumerated()
                .filter { $0.offset != index }
                .map(\.element)
            environments[index].name = Self.uniqueEnvironmentName(
                environments[index].name, among: others)
        }
        environments.sort { $0.name < $1.name }
        environmentsRevision += 1
        await save()
        // Cleared *after* the write, not before. `save` suspends, and a watcher callback landing
        // in that window would otherwise find the flag already down, reload the files as they were
        // before the write, and hand `save` an empty array to persist. That is not theoretical:
        // clearing it first made three of the tests below fail, in a different combination each
        // run, which is what an FSEvents race looks like from the outside.
        hasStagedEnvironmentChanges = false
    }

    private static func uniqueEnvironmentName(
        _ name: String,
        among existing: [NibCore.Environment]
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New environment" : trimmed
        let taken = Set(existing.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: - Keychain

    /// Put secret values back into the environments just read from disk.
    ///
    /// The files carry `"value": null` for every secret, so without this step opening a collection
    /// would present each token as empty and the first save would then reconcile the Keychain
    /// against those empties — deleting them. That is why a failure here sets `secretsFailure`
    /// and why `synchroniseSecrets` refuses to run while it is set.
    func hydrateSecrets() async {
        // Same rule as `apply`: never overwrite what the user has typed but not yet saved.
        guard let collection, !hasStagedEnvironmentChanges else { return }
        secretsFailure = nil

        let prefix = SecretStore.prefix(collectionID: collection.id)
        let stored: [String: String]
        do {
            stored = try await secretStore.load(prefix: prefix)
        } catch {
            secretsFailure = Self.describeSecretFailure(error)
            return
        }

        // Re-check after the await, not only before it.
        //
        // Reading the Keychain suspends, and an edit can be staged while it is suspended — so the
        // guard at the top of this method can pass, the user can type a token, and this can then
        // overwrite it with what the Keychain held a moment *earlier*, which is nothing. The next
        // save reconciles against that blank and the secret is gone.
        //
        // Same shape as the stale-snapshot check in `reloadIfChangedExternally`, and it presented
        // the same way: one failure in ten full-suite runs, never in isolation.
        guard !hasStagedEnvironmentChanges else { return }

        for environmentIndex in environments.indices {
            let environment = environments[environmentIndex]
            for variableIndex in environment.variables.indices
            where environment.variables[variableIndex].secret {
                let account = SecretStore.account(
                    collectionID: collection.id,
                    environmentName: environment.name,
                    key: environment.variables[variableIndex].key)
                environments[environmentIndex].variables[variableIndex].value = stored[account]
            }
        }
    }

    /// Make the Keychain match the secrets currently in memory.
    ///
    /// Called from `save`, after the files are written. A secret with no value is deliberately
    /// *not* written as an empty string — on a cloned repo that is the normal state, and storing
    /// an empty value would turn "you need to paste your token" into a silent 401.
    func synchroniseSecrets() async {
        guard let collection, secretsFailure == nil else { return }

        var entries: [String: String] = [:]
        for environment in environments {
            for variable in environment.variables where variable.secret {
                guard let value = variable.value, !value.isEmpty else { continue }
                entries[
                    SecretStore.account(
                        collectionID: collection.id,
                        environmentName: environment.name,
                        key: variable.key)] = value
            }
        }

        do {
            try await secretStore.synchronise(
                prefix: SecretStore.prefix(collectionID: collection.id), entries: entries)
        } catch {
            secretsFailure = Self.describeSecretFailure(error)
        }
    }

    private static func describeSecretFailure(_ error: any Error) -> String {
        let detail = (error as? SecretStore.SecretError)?.description ?? error.localizedDescription
        return
            "Secrets are unavailable, so Nib will not change them. \(detail)"
    }
}
