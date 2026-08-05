import Foundation
import NibCore
import NibTestSupport
import Testing

@testable import NibStore

/// These talk to the real Keychain, under their own service name so they can never see or
/// destroy a secret belonging to whoever is running them.
///
/// Skipped rather than failed when the Keychain is unavailable — a locked login keychain, or a
/// CI runner with no keychain at all, is an environment problem and not a defect in this code.
/// A red suite that means "your machine is configured differently" trains people to ignore red.
@Suite("SecretStore", .serialized, .enabled(if: KeychainProbe.isUsable))
struct SecretStoreTests {

    private static let service = "app.nib.secret.tests"
    private let collectionID = NodeID(rawValue: "01TESTCOLLECTION0000000000")

    private func makeStore() -> SecretStore {
        SecretStore(service: Self.service)
    }

    /// Leave nothing behind, whichever way the test exits.
    private func withCleanStore(_ body: (SecretStore) async throws -> Void) async throws {
        let store = makeStore()
        KeychainProbe.deleteEverything(inService: Self.service)
        defer { KeychainProbe.deleteEverything(inService: Self.service) }
        try await body(store)
    }

    // MARK: - Account naming

    @Test("accounts are readable and namespaced by collection")
    func accountFormat() {
        let account = SecretStore.account(
            collectionID: collectionID, environmentName: "Staging", key: "API_TOKEN")

        #expect(account == "01TESTCOLLECTION0000000000/Staging/API_TOKEN")
        #expect(account.hasPrefix(SecretStore.prefix(collectionID: collectionID)))
    }

    // MARK: - Round trips

    @Test("stores and reads a value back")
    func roundTrip() async throws {
        try await withCleanStore { store in
            let account = SecretStore.account(
                collectionID: collectionID, environmentName: "Staging", key: "TOKEN")

            #expect(try await store.value(for: account) == nil)
            try await store.set("sk-live-123", for: account)
            #expect(try await store.value(for: account) == "sk-live-123")
        }
    }

    /// `SecItemAdd` returns `errSecDuplicateItem` rather than overwriting, so without the update
    /// path in `set` the second save of a rotated token would silently keep the old one.
    @Test("a second write replaces the value rather than failing")
    func overwrite() async throws {
        try await withCleanStore { store in
            let account = SecretStore.account(
                collectionID: collectionID, environmentName: "Staging", key: "TOKEN")

            try await store.set("first", for: account)
            try await store.set("second", for: account)
            #expect(try await store.value(for: account) == "second")
        }
    }

    @Test("deleting something absent is not an error")
    func idempotentDelete() async throws {
        try await withCleanStore { store in
            let account = SecretStore.account(
                collectionID: collectionID, environmentName: "Gone", key: "NOPE")
            try await store.remove(account)
            try await store.remove(account)
            #expect(try await store.value(for: account) == nil)
        }
    }

    @Test("values survive characters that are awkward in a shell or a URL")
    func awkwardValues() async throws {
        try await withCleanStore { store in
            let value = "p@ss w/ord \"quoted\" $(not a command) — ünïcode\n"
            let account = SecretStore.account(
                collectionID: collectionID, environmentName: "Local", key: "PASSWORD")

            try await store.set(value, for: account)
            #expect(try await store.value(for: account) == value)
        }
    }

    // MARK: - Whole-collection operations

    @Test("load returns only accounts under the requested prefix")
    func prefixScoping() async throws {
        try await withCleanStore { store in
            let other = NodeID(rawValue: "01OTHERCOLLECTION000000000")

            try await store.set(
                "mine",
                for: SecretStore.account(
                    collectionID: collectionID, environmentName: "Staging", key: "TOKEN"))
            try await store.set(
                "theirs",
                for: SecretStore.account(
                    collectionID: other, environmentName: "Staging", key: "TOKEN"))

            let loaded = try await store.load(
                prefix: SecretStore.prefix(collectionID: collectionID))

            #expect(loaded.count == 1)
            #expect(loaded.values.first == "mine")
        }
    }

    /// Renaming an environment, deleting one, or unticking "secret" all reach the Keychain only
    /// through this method. If it did not prune, the old entry would stay in the user's Keychain
    /// forever with no way to reach it from inside Nib.
    @Test("synchronise adds, updates and prunes to match exactly")
    func synchronisePrunes() async throws {
        try await withCleanStore { store in
            let prefix = SecretStore.prefix(collectionID: collectionID)
            func account(_ environment: String, _ key: String) -> String {
                SecretStore.account(
                    collectionID: collectionID, environmentName: environment, key: key)
            }

            try await store.synchronise(
                prefix: prefix,
                entries: [
                    account("Staging", "TOKEN"): "one",
                    account("Staging", "OLD"): "two",
                ])
            #expect(try await store.load(prefix: prefix).count == 2)

            // Rename Staging -> Production, drop OLD, rotate TOKEN.
            try await store.synchronise(
                prefix: prefix, entries: [account("Production", "TOKEN"): "rotated"])

            let after = try await store.load(prefix: prefix)
            #expect(after == [account("Production", "TOKEN"): "rotated"])
            #expect(try await store.value(for: account("Staging", "OLD")) == nil)
        }
    }

    @Test("synchronise leaves other collections alone")
    func synchroniseIsScoped() async throws {
        try await withCleanStore { store in
            let other = NodeID(rawValue: "01OTHERCOLLECTION000000000")
            let theirs = SecretStore.account(
                collectionID: other, environmentName: "Staging", key: "TOKEN")
            try await store.set("theirs", for: theirs)

            try await store.synchronise(
                prefix: SecretStore.prefix(collectionID: collectionID), entries: [:])

            #expect(try await store.value(for: theirs) == "theirs")
        }
    }
}
