import Foundation
import NibCore
import NibStore
import NibTestSupport
import Testing

@testable import NibUI

/// Reopening a collection and finding the environment actually applied.
///
/// Its own suite rather than another case in `EnvironmentsTests`, which is already at the length
/// limit — and this is a different question anyway: not "does resolution work" but "is anything
/// wired to re-run it when the environment is chosen during load".
@Suite("Environment restore", .serialized, .enabled(if: KeychainProbe.isUsable))
struct EnvironmentRestoreTests {

    /// Test-only Keychain namespace. Nothing here can see or delete a real secret.
    private static let service = "app.nib.secret.restoretests"

    /// Picking the environment during load happens after the selection has already computed its
    /// scope, so the revision has to move or the first request you look at resolves against
    /// nothing — the picker says "Local", the badge says two variables, and sending fails with
    /// "That URL could not be parsed" until you switch requests and back.
    @Test("reopening a collection re-resolves against the restored environment")
    func reopeningReResolves() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        KeychainProbe.deleteEverything(inService: Self.service)
        defer {
            KeychainProbe.deleteEverything(inService: Self.service)
            try? FileManager.default.removeItem(at: root)
        }

        let model = CollectionModel(secretStore: SecretStore(service: Self.service))
        await model.open(root)
        await model.addRequest(named: "List users")

        let localID = model.stageAddEnvironment(named: "Local")
        model.stage(
            NibCore.Environment(
                id: localID, name: "Local",
                variables: [.init(key: "baseUrl", value: "http://127.0.0.1:8795")]))
        await model.commitEnvironments()
        model.setActiveEnvironment(localID)
        // Stop the FSEvents watcher before reopening, or the first model keeps reacting to the
        // second one's writes.
        model.close()

        // Reopen exactly as launching the app on this folder would.
        let reopened = CollectionModel(secretStore: SecretStore(service: Self.service))
        let before = reopened.environmentsRevision
        await reopened.open(root)
        defer { reopened.close() }

        #expect(reopened.activeEnvironmentID == localID)
        #expect(
            reopened.environmentsRevision > before,
            "the revision must move, or nothing recomputes the scope")

        let requestID = try #require(reopened.selectedRequestID)
        let scope = reopened.scope(forRequestWithID: requestID)
        #expect(scope.value(for: "baseUrl") == "http://127.0.0.1:8795")
    }
}
