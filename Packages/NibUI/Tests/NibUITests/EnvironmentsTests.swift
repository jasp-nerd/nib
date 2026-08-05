import Foundation
import NibCore
import NibStore
import NibTestSupport
import Testing

@testable import NibUI

/// The Phase 5 acceptance test, in code: flip environment, the same request goes somewhere else,
/// and the file in git still has `"value": null` where the token is.
@Suite("Environments", .serialized, .enabled(if: KeychainProbe.isUsable))
struct EnvironmentsTests {

    /// Test-only Keychain namespace. Nothing here can see or delete a real secret.
    private static let service = "app.nib.secret.uitests"

    /// A collection folder with one request whose URL is entirely variables, plus a collection
    /// default for `baseUrl` pointing at production — the setup that makes a precedence mistake
    /// visible instead of subtle.
    private func withCollection(
        _ body: (CollectionModel, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        KeychainProbe.deleteEverything(inService: Self.service)
        defer {
            KeychainProbe.deleteEverything(inService: Self.service)
            try? FileManager.default.removeItem(at: root)
        }

        let model = CollectionModel(secretStore: SecretStore(service: Self.service))
        await model.open(root)
        await model.addRequest(named: "Get user")
        // Stop the FSEvents watcher before the folder is deleted. Without this each test leaves a
        // live watcher behind and the next one inherits its callbacks.
        defer { model.close() }

        try await body(model, root)
    }

    private func environmentFile(in root: URL, named name: String) throws -> String {
        let url =
            root
            .appendingPathComponent(StoreLocations.environmentsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(name).\(StoreLocations.environmentFileExtension)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Resolution

    @Test("switching environment sends the same request somewhere else")
    func switchingEnvironmentChangesTheHost() async throws {
        try await withCollection { model, _ in
            let requestID = try #require(model.selectedRequestID)

            let localID = model.stageAddEnvironment(named: "Local")
            model.stage(
                NibCore.Environment(
                    id: localID, name: "Local",
                    variables: [.init(key: "baseUrl", value: "http://localhost:3000")]))

            let stagingID = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: stagingID, name: "Staging",
                    variables: [.init(key: "baseUrl", value: "https://staging.acme.dev")]))

            model.setActiveEnvironment(localID)
            #expect(
                VariableResolver.resolve(
                    "{{baseUrl}}/users", in: model.scope(forRequestWithID: requestID)
                ).text == "http://localhost:3000/users")

            model.setActiveEnvironment(stagingID)
            #expect(
                VariableResolver.resolve(
                    "{{baseUrl}}/users", in: model.scope(forRequestWithID: requestID)
                ).text == "https://staging.acme.dev/users")

            // And "no environment" is a real choice, not an empty state.
            model.setActiveEnvironment(nil)
            #expect(model.scope(forRequestWithID: requestID).value(for: "baseUrl") == nil)
        }
    }

    /// The regression guard from `VariableScope`, exercised through the model rather than the
    /// type — this is the wiring that would make selecting Staging silently hit production.
    @Test("the environment layer beats the collection layer through the model")
    func environmentBeatsCollectionEndToEnd() async throws {
        try await withCollection { model, _ in
            let requestID = try #require(model.selectedRequestID)

            let id = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Staging",
                    variables: [.init(key: "baseUrl", value: "https://staging.acme.dev")]))
            model.setActiveEnvironment(id)

            let scope = model.scope(forRequestWithID: requestID)
            #expect(scope.value(for: "baseUrl") == "https://staging.acme.dev")
            #expect(scope.definingLayer(for: "baseUrl") == .environment)
        }
    }

    @Test("a disabled variable resolves as if it were not there")
    func disabledVariable() async throws {
        try await withCollection { model, _ in
            let requestID = try #require(model.selectedRequestID)
            let id = model.stageAddEnvironment(named: "Local")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Local",
                    variables: [
                        .init(key: "baseUrl", value: "http://localhost:3000", enabled: false)
                    ]))
            model.setActiveEnvironment(id)

            #expect(model.scope(forRequestWithID: requestID).value(for: "baseUrl") == nil)
        }
    }

    // MARK: - Secrets

    @Test("a secret's value goes to the Keychain and never to the file")
    func secretsStayOutOfTheFile() async throws {
        try await withCollection { model, root in
            let id = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Staging",
                    variables: [
                        .init(key: "baseUrl", value: "https://staging.acme.dev"),
                        .init(key: "TOKEN", value: "sk-live-do-not-commit", secret: true),
                    ]))
            await model.commitEnvironments()

            let contents = try environmentFile(in: root, named: "Staging")
            #expect(!contents.contains("sk-live-do-not-commit"))
            // The key still has to be *visible* in the file — that is what lets a clone on another
            // machine know a token is expected and prompt for it.
            #expect(contents.contains("\"TOKEN\""))
            #expect(contents.contains("\"value\" : null"))

            let store = SecretStore(service: Self.service)
            let collectionID = try #require(model.collection?.id)
            let account = SecretStore.account(
                collectionID: collectionID, environmentName: "Staging", key: "TOKEN")
            #expect(try await store.value(for: account) == "sk-live-do-not-commit")
        }
    }

    @Test("reopening a collection puts secret values back")
    func secretsRehydrateOnReopen() async throws {
        try await withCollection { model, root in
            let id = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Staging",
                    variables: [.init(key: "TOKEN", value: "sk-live-123", secret: true)]))
            await model.commitEnvironments()

            let reopened = CollectionModel(secretStore: SecretStore(service: Self.service))
            await reopened.open(root)
            defer { reopened.close() }

            let environment = try #require(reopened.environments.first { $0.name == "Staging" })
            #expect(environment.variables.first?.value == "sk-live-123")
            #expect(reopened.secretsFailure == nil)
        }
    }

    /// The clone case. Same files, empty Keychain: the key is known, the value is not, and the
    /// placeholder must stay unresolved rather than resolving to an empty string.
    @Test("a clone with no Keychain entry reports the variable as unresolved")
    func cloneWithoutSecrets() async throws {
        try await withCollection { model, root in
            let requestID = try #require(model.selectedRequestID)
            let id = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Staging",
                    variables: [.init(key: "TOKEN", value: "sk-live-123", secret: true)]))
            await model.commitEnvironments()

            KeychainProbe.deleteEverything(inService: Self.service)

            let clone = CollectionModel(secretStore: SecretStore(service: Self.service))
            await clone.open(root)

            let environment = try #require(clone.environments.first { $0.name == "Staging" })
            #expect(environment.variables.first?.key == "TOKEN")
            #expect(environment.variables.first?.value == nil)

            let cloneRequestID = try #require(clone.selectedRequestID)
            let resolved = VariableResolver.resolve(
                "Bearer {{TOKEN}}", in: clone.scope(forRequestWithID: cloneRequestID))
            #expect(resolved.text == "Bearer {{TOKEN}}")
            #expect(resolved.unresolved.map(\.name) == ["TOKEN"])

            _ = requestID
        }
    }

    // MARK: - Renaming and deleting

    @Test("renaming an environment moves its secret and removes the old file")
    func renameMovesEverything() async throws {
        try await withCollection { model, root in
            let id = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Staging",
                    variables: [.init(key: "TOKEN", value: "sk-live-123", secret: true)]))
            await model.commitEnvironments()

            var renamed = try #require(model.environments.first { $0.id == id })
            renamed.name = "Production"
            model.stage(renamed)
            await model.commitEnvironments()

            #expect(throws: (any Error).self) {
                try environmentFile(in: root, named: "Staging")
            }
            #expect(try environmentFile(in: root, named: "Production").contains("\"TOKEN\""))

            let store = SecretStore(service: Self.service)
            let collectionID = try #require(model.collection?.id)
            #expect(
                try await store.value(
                    for: SecretStore.account(
                        collectionID: collectionID, environmentName: "Production", key: "TOKEN"))
                    == "sk-live-123")
            #expect(
                try await store.value(
                    for: SecretStore.account(
                        collectionID: collectionID, environmentName: "Staging", key: "TOKEN"))
                    == nil)
        }
    }

    @Test("deleting an environment takes its file and its secrets with it")
    func deleteRemovesEverything() async throws {
        try await withCollection { model, root in
            let id = model.stageAddEnvironment(named: "Staging")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Staging",
                    variables: [.init(key: "TOKEN", value: "sk-live-123", secret: true)]))
            await model.commitEnvironments()

            let collectionID = try #require(model.collection?.id)
            model.stageDeleteEnvironment(id)
            await model.commitEnvironments()

            #expect(throws: (any Error).self) {
                try environmentFile(in: root, named: "Staging")
            }
            let store = SecretStore(service: Self.service)
            #expect(
                try await store.load(
                    prefix: SecretStore.prefix(collectionID: collectionID)
                ).isEmpty)
        }
    }

    @Test("two environments cannot end up sharing a filename")
    func nameCollisionsAreResolvedOnCommit() async throws {
        try await withCollection { model, _ in
            let first = model.stageAddEnvironment(named: "Staging")
            let second = model.stageAddEnvironment(named: "Local")

            var collided = try #require(model.environments.first { $0.id == second })
            collided.name = "Staging"
            model.stage(collided)
            await model.commitEnvironments()

            let names = model.environments.map(\.name).sorted()
            #expect(names == ["Staging", "Staging 2"])
            #expect(first != second)
        }
    }

    // MARK: - Warnings before send

    @Test("unresolved variables are reported before a send, not only after")
    func pendingUnresolved() async throws {
        try await withCollection { model, _ in
            let requestID = try #require(model.selectedRequestID)
            let id = model.stageAddEnvironment(named: "Local")
            model.stage(
                NibCore.Environment(
                    id: id, name: "Local",
                    variables: [.init(key: "baseUrl", value: "http://localhost:3000")]))
            model.setActiveEnvironment(id)

            let session = RequestSession(
                spec: HTTPRequestSpec(url: "{{baseUrl}}/users/{{userId}}"),
                scope: model.scope(forRequestWithID: requestID),
                engine: .init()
            )
            session.spec.headers = [
                HeaderField(name: "Authorization", value: "Bearer {{TOKEN}}"),
                HeaderField(name: "X-Off", value: "{{ignored}}", enabled: false),
            ]

            #expect(session.unresolved.isEmpty)
            // Reported once each, in the order they appear, and the disabled header is not
            // reported at all because it is not going to be sent.
            #expect(session.pendingUnresolved == ["userId", "TOKEN"])
        }
    }

    @Test("dynamic values are not reported as unresolved")
    func dynamicValuesAreNotWarnings() async throws {
        let session = RequestSession(
            spec: HTTPRequestSpec(url: "https://api.example.com/x?nonce={{$guid}}"),
            engine: .init()
        )
        #expect(session.pendingUnresolved.isEmpty)
    }
}
