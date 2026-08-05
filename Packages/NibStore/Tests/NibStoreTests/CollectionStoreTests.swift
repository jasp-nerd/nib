import Foundation
import NibCore
import Testing

@testable import NibStore

// swiftlint:disable type_body_length
// A long, flat suite over one subject.

/// The store's correctness is entirely about what lands on disk, so these tests write to a real
/// temporary directory and read the bytes back. Mocking the filesystem would test the mock.
@Suite("CollectionStore")
struct CollectionStoreTests {

    // MARK: - Harness

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-store-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func sampleCollection() -> NibCore.Collection {
        NibCore.Collection(
            id: NodeID(rawValue: "01COLLECTION0000000000000"),
            name: "Acme API",
            children: [
                .folder(
                    FolderNode(
                        id: NodeID(rawValue: "01FOLDERAUTH000000000000"),
                        name: "Auth",
                        children: [
                            .request(
                                RequestNode(
                                    id: NodeID(rawValue: "01REQLOGIN0000000000000"),
                                    name: "Login",
                                    spec: HTTPRequestSpec(
                                        method: .post,
                                        url: "{{baseUrl}}/login",
                                        headers: [
                                            HeaderField(
                                                name: "Content-Type", value: "application/json")
                                        ],
                                        body: .raw(
                                            text: "{\n  \"user\": \"ada\"\n}", language: .json)
                                    )))
                        ],
                        auth: .bearer(token: "{{folderToken}}"))),
                .request(
                    RequestNode(
                        id: NodeID(rawValue: "01REQLIST00000000000000"),
                        name: "List users",
                        spec: HTTPRequestSpec(url: "{{baseUrl}}/users"))),
            ],
            auth: .bearer(token: "{{token}}"),
            variables: [EnvironmentVariable(key: "baseUrl", value: "https://api.acme.dev")]
        )
    }

    // MARK: - Round trip

    @Test("a collection survives a save and load unchanged")
    func roundTrip() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            let original = sampleCollection()

            try await store.save(original)
            let loaded = try await store.load()

            #expect(loaded.collection.name == original.name)
            #expect(loaded.collection.id == original.id)
            #expect(loaded.collection.auth == original.auth)
            #expect(loaded.collection.variables == original.variables)
            #expect(loaded.diagnostics.isEmpty)

            // Order is preserved: the folder came first.
            #expect(loaded.collection.children.map(\.name) == ["Auth", "List users"])
            #expect(loaded.collection.children.first?.isFolder == true)

            let requests = loaded.collection.allRequests
            #expect(requests.count == 2)

            let login = try #require(requests.first { $0.request.name == "Login" })
            #expect(login.request.id == NodeID(rawValue: "01REQLOGIN0000000000000"))
            #expect(login.request.spec.method == .post)
            #expect(login.path.map(\.name) == ["Auth"])
            guard case .raw(let body, let language) = login.request.spec.body else {
                Issue.record("expected a raw body, got \(login.request.spec.body)")
                return
            }
            #expect(body == "{\n  \"user\": \"ada\"\n}")
            #expect(language == .json)
        }
    }

    /// The bodies-in-sibling-files rule is what makes the git story work, so it is a hard assertion
    /// about the layout rather than an implementation detail.
    @Test("request bodies are written to sibling files, not inlined")
    func bodiesAreSiblingFiles() async throws {
        try await withTemporaryDirectory { root in
            try await CollectionStore(root: root).save(sampleCollection())

            let requestFile = root.appendingPathComponent("Auth/Login.req.json")
            let bodyFile = root.appendingPathComponent("Auth/Login.req.body.json")

            #expect(FileManager.default.fileExists(atPath: requestFile.path))
            #expect(FileManager.default.fileExists(atPath: bodyFile.path))

            let requestText = try String(contentsOf: requestFile, encoding: .utf8)
            // The body's content must not appear in the request JSON at all.
            #expect(!requestText.contains("ada"))
            #expect(requestText.contains("Login.req.body.json"))

            let bodyText = try String(contentsOf: bodyFile, encoding: .utf8)
            #expect(bodyText == "{\n  \"user\": \"ada\"\n}")
            // Real newlines, not `\n` escapes -- that is the entire point.
            #expect(!bodyText.contains("\\n"))
        }
    }

    @Test("the layout on disk is the one documented in docs/on-disk-format.md")
    func layout() async throws {
        try await withTemporaryDirectory { root in
            try await CollectionStore(root: root).save(sampleCollection())

            for path in [
                "collection.json",
                ".gitignore",
                "Auth/folder.json",
                "Auth/Login.req.json",
                "Auth/Login.req.body.json",
                "List users.req.json",
            ] {
                #expect(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(path).path),
                    "missing \(path)")
            }
        }
    }

    // MARK: - Determinism

    /// Same model, same bytes. Without this every save churns the diff and `git status` is never
    /// clean, which retires the second-biggest pitch of the product.
    @Test("saving the same collection twice produces identical bytes")
    func deterministicWrites() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            let collection = sampleCollection()

            try await store.save(collection)
            let first = try snapshot(of: root)

            try await store.save(collection)
            let second = try snapshot(of: root)

            #expect(first == second)
        }
    }

    @Test("a load-then-save cycle does not change the bytes")
    func idempotentRoundTrip() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            try await store.save(sampleCollection())
            let before = try snapshot(of: root)

            let loaded = try await store.load()
            try await store.save(loaded.collection, environments: loaded.environments)
            let after = try snapshot(of: root)

            // Opening a collection and saving it without edits must be a no-op in git.
            #expect(before == after)
        }
    }

    private func snapshot(of root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false else {
                continue
            }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            result[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    // MARK: - Order reconciliation

    @Test("declared order wins, and unlisted files are appended alphabetically")
    func orderReconciliation() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            try await store.save(
                NibCore.Collection(
                    name: "C",
                    children: [
                        .request(
                            RequestNode(name: "Zebra", spec: HTTPRequestSpec(url: "https://z"))),
                        .request(
                            RequestNode(name: "Apple", spec: HTTPRequestSpec(url: "https://a"))),
                    ]))

            // The declared order is Zebra, Apple -- deliberately not alphabetical.
            #expect(try await store.load().collection.children.map(\.name) == ["Zebra", "Apple"])
        }
    }

    /// Copying a file in from Finder has to just work, or the "these are your files" claim is hollow.
    @Test("a request file added by hand shows up without touching order")
    func fileAddedByHandAppears() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            try await store.save(
                NibCore.Collection(
                    name: "C",
                    children: [
                        .request(
                            RequestNode(name: "Existing", spec: HTTPRequestSpec(url: "https://e")))
                    ]))

            // Simulate `cp` from Finder: a valid request file that `order` knows nothing about.
            let handWritten = """
                {
                  "auth" : { "type" : "inherit" },
                  "body" : { "type" : "none" },
                  "formatVersion" : 1,
                  "headers" : [],
                  "id" : "01HANDWRITTEN0000000000",
                  "method" : "GET",
                  "params" : [],
                  "settings" : {
                    "followRedirects" : true,
                    "maximumRedirects" : 10,
                    "preserveMethodOnRedirect" : false,
                    "sendBodyOnGet" : false,
                    "timeoutMilliseconds" : 30000,
                    "verifyTLS" : true
                  },
                  "url" : "https://added-by-hand.example"
                }

                """
            try Data(handWritten.utf8).write(
                to: root.appendingPathComponent("Added.req.json"))

            let loaded = try await store.load()
            #expect(loaded.collection.children.map(\.name) == ["Existing", "Added"])
            #expect(loaded.diagnostics.isEmpty)
        }
    }

    // MARK: - Tolerance
    //
    // A folder someone has been editing by hand must still open.

    @Test("a malformed request is skipped with a diagnostic, not a failed load")
    func malformedRequestIsSkipped() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            try await store.save(
                NibCore.Collection(
                    name: "C",
                    children: [
                        .request(RequestNode(name: "Good", spec: HTTPRequestSpec(url: "https://g")))
                    ]))

            try Data("{ this is not json".utf8).write(
                to: root.appendingPathComponent("Broken.req.json"))

            let loaded = try await store.load()
            // The good one still loads; the bad one is reported.
            #expect(loaded.collection.children.map(\.name) == ["Good"])
            #expect(loaded.diagnostics.count == 1)
            #expect(loaded.diagnostics[0].contains("Broken.req.json"))
        }
    }

    @Test("unrelated files and directories are ignored, never adopted")
    func ignoresForeignEntries() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            try await store.save(NibCore.Collection(name: "C"))

            try Data("# notes".utf8).write(to: root.appendingPathComponent("README.md"))
            let scratch = root.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: scratch.appendingPathComponent("notes.txt"))

            let loaded = try await store.load()
            #expect(loaded.collection.children.isEmpty)

            // And a later save must not delete them.
            try await store.save(loaded.collection)
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("README.md").path))
            #expect(
                FileManager.default.fileExists(
                    atPath: scratch.appendingPathComponent("notes.txt").path))
        }
    }

    @Test("loading a directory with no collection.json is a clear error")
    func missingCollectionFile() async throws {
        try await withTemporaryDirectory { root in
            await #expect(throws: CollectionStore.StoreError.self) {
                _ = try await CollectionStore(root: root).load()
            }
        }
    }

    @Test("a future format version is refused rather than misread")
    func futureFormatVersion() async throws {
        try await withTemporaryDirectory { root in
            let future = """
                { "formatVersion" : 999, "id" : "x", "name" : "C", "order" : [],
                  "auth" : { "type" : "none" }, "variables" : [] }
                """
            try Data(future.utf8).write(
                to: root.appendingPathComponent("collection.json"))

            await #expect(
                throws: CollectionStore.StoreError.unsupportedFormatVersion(999)
            ) {
                _ = try await CollectionStore(root: root).load()
            }
        }
    }

    // MARK: - Renames and deletions

    @Test("renaming a request renames its files and leaves no duplicate")
    func renameMovesFiles() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            let id = NodeID(rawValue: "01STABLE00000000000000")

            try await store.save(
                NibCore.Collection(
                    name: "C",
                    children: [
                        .request(
                            RequestNode(
                                id: id, name: "Before",
                                spec: HTTPRequestSpec(
                                    url: "https://x", body: .raw(text: "{}", language: .json))))
                    ]))
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Before.req.json").path))

            try await store.save(
                NibCore.Collection(
                    name: "C",
                    children: [
                        .request(
                            RequestNode(
                                id: id, name: "After",
                                spec: HTTPRequestSpec(
                                    url: "https://x", body: .raw(text: "{}", language: .json))))
                    ]))

            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Before.req.json").path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("Before.req.body.json").path))
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("After.req.json").path))

            // The id survives the rename, so history and open tabs stay attached.
            #expect(try await store.load().collection.allRequests.first?.request.id == id)
        }
    }

    // MARK: - Filenames

    @Test(
        "display names are sanitised into safe filenames",
        arguments: [
            ("Get users", "Get users"),
            ("GET /users", "GET -users"),
            ("a:b", "a-b"),
            (".hidden", "hidden"),
            ("  padded  ", "padded"),
            ("", "Untitled"),
            ("...", "Untitled"),
        ]
    )
    func sanitisation(input: String, expected: String) {
        #expect(CollectionStore.sanitise(input) == expected)
    }

    @Test("a name with a slash does not create a subdirectory")
    func slashDoesNotEscape() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            try await store.save(
                NibCore.Collection(
                    name: "C",
                    children: [
                        .request(
                            RequestNode(
                                name: "GET /users/:id", spec: HTTPRequestSpec(url: "https://x")))
                    ]))

            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            // Both `/` and `:` are sanitised, so `:id` becomes `-id`.
            #expect(contents.contains("GET -users--id.req.json"))
            // Nothing escaped into a nested directory.
            #expect(
                !FileManager.default.fileExists(atPath: root.appendingPathComponent("GET ").path))
        }
    }

    // MARK: - Secrets

    /// The single most important guarantee in this package.
    @Test("secret environment values are never written to disk")
    func secretsNeverHitDisk() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            let environment = NibCore.Environment(
                name: "Staging",
                variables: [
                    EnvironmentVariable(key: "baseUrl", value: "https://staging.example"),
                    EnvironmentVariable(key: "token", value: "sk_live_do_not_leak", secret: true),
                ])

            try await store.save(NibCore.Collection(name: "C"), environments: [environment])

            let file = root.appendingPathComponent("environments/Staging.env.json")
            let text = try String(contentsOf: file, encoding: .utf8)

            #expect(!text.contains("sk_live_do_not_leak"))
            #expect(text.contains("baseUrl"))
            // The key is still recorded, with a null value, so a clone knows to prompt.
            #expect(text.contains("token"))
            #expect(text.contains("null"))

            let loaded = try await store.load()
            let token = try #require(
                loaded.environments.first?.variables.first { $0.key == "token" })
            #expect(token.secret)
            #expect(token.value == nil)
        }
    }

    // MARK: - Write generation

    /// The watcher reports our own writes too. Without a generation to compare against, the app would
    /// reload the tree it just saved and discard whatever the user typed next.
    @Test("each save bumps the write generation")
    func writeGeneration() async throws {
        try await withTemporaryDirectory { root in
            let store = CollectionStore(root: root)
            #expect(await store.currentWriteGeneration == 0)

            try await store.save(NibCore.Collection(name: "C"))
            #expect(await store.currentWriteGeneration == 1)

            try await store.save(NibCore.Collection(name: "C"))
            #expect(await store.currentWriteGeneration == 2)
        }
    }

    // MARK: - Inherited auth

    @Test("auth resolves innermost folder first, then the collection")
    func inheritedAuth() {
        let collection = sampleCollection()
        let requests = collection.allRequests

        let login = requests.first { $0.request.name == "Login" }
        let inherited = collection.inheritedAuth(forRequestAt: login?.path ?? [])
        // The Auth folder overrides the collection's own token.
        #expect(inherited == .bearer(token: "{{folderToken}}"))

        let list = requests.first { $0.request.name == "List users" }
        #expect(
            collection.inheritedAuth(forRequestAt: list?.path ?? [])
                == .bearer(token: "{{token}}"))
    }
}
