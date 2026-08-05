import Foundation
import NibCore
import Testing

@testable import NibStore

@Suite("HistoryStore")
struct HistoryStoreTests {

    private func withStore(_ body: (HistoryStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(HistoryStore(directory: directory), directory)
    }

    private func entry(_ index: Int, status: Int = 200) -> HistoryStore.Entry {
        HistoryStore.Entry(
            id: "entry-\(index)",
            date: Date(timeIntervalSince1970: TimeInterval(index)),
            method: "GET",
            url: "https://api.example.com/users/\(index)",
            status: status,
            durationMilliseconds: 12.5,
            byteCount: 100,
            bodyPreview: "{\"index\": \(index)}",
            isBodyTruncated: false)
    }

    private let request = NodeID(rawValue: "01HISTORYREQUEST0000000000")

    @Test("an empty history reads as empty rather than failing")
    func emptyHistory() async throws {
        try await withStore { store, _ in
            #expect(await store.entries(forRequest: request).isEmpty)
        }
    }

    @Test("entries come back newest first")
    func newestFirst() async throws {
        try await withStore { store, _ in
            for index in 1...3 {
                await store.record(entry(index), forRequest: request)
            }
            let entries = await store.entries(forRequest: request)
            #expect(entries.map(\.id) == ["entry-3", "entry-2", "entry-1"])
        }
    }

    @Test("history round-trips through disk with its dates intact")
    func roundTrip() async throws {
        try await withStore { store, directory in
            await store.record(entry(1, status: 404), forRequest: request)

            let reopened = try HistoryStore(directory: directory)
            let entries = await reopened.entries(forRequest: request)

            let first = try #require(entries.first)
            #expect(first.status == 404)
            #expect(first.date == Date(timeIntervalSince1970: 1))
            #expect(first.url == "https://api.example.com/users/1")
        }
    }

    @Test("the oldest entries fall off once the limit is reached")
    func limitEnforced() async throws {
        try await withStore { store, _ in
            for index in 1...(HistoryStore.limit + 5) {
                await store.record(entry(index), forRequest: request)
            }
            let entries = await store.entries(forRequest: request)
            #expect(entries.count == HistoryStore.limit)
            #expect(entries.first?.id == "entry-\(HistoryStore.limit + 5)")
            #expect(entries.last?.id == "entry-6")
        }
    }

    @Test("each request keeps its own history")
    func perRequestIsolation() async throws {
        try await withStore { store, _ in
            let other = NodeID(rawValue: "01HISTORYOTHER000000000000")
            await store.record(entry(1), forRequest: request)
            await store.record(entry(2), forRequest: other)

            #expect(await store.entries(forRequest: request).map(\.id) == ["entry-1"])
            #expect(await store.entries(forRequest: other).map(\.id) == ["entry-2"])
        }
    }

    /// Deleting a request must not leave its responses on disk. They are invisible from the app and
    /// still contain whatever the API returned.
    @Test("pruning removes history for requests that no longer exist")
    func pruning() async throws {
        try await withStore { store, _ in
            let gone = NodeID(rawValue: "01HISTORYDELETED0000000000")
            await store.record(entry(1), forRequest: request)
            await store.record(entry(2), forRequest: gone)

            await store.prune(keeping: [request])

            #expect(await store.entries(forRequest: request).count == 1)
            #expect(await store.entries(forRequest: gone).isEmpty)
        }
    }

    @Test("clearing one request's history leaves the others alone")
    func clearing() async throws {
        try await withStore { store, _ in
            let other = NodeID(rawValue: "01HISTORYOTHER000000000000")
            await store.record(entry(1), forRequest: request)
            await store.record(entry(2), forRequest: other)

            await store.clear(forRequest: request)

            #expect(await store.entries(forRequest: request).isEmpty)
            #expect(await store.entries(forRequest: other).count == 1)
        }
    }

    /// A convenience must never be able to fail a request that actually worked.
    @Test("an unwritable directory is silently tolerated")
    func unwritableDirectoryIsNotFatal() async throws {
        // A path under a regular file cannot be created as a directory.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-history-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let store = try HistoryStore(directory: file.appendingPathComponent("inside"))
        await store.record(entry(1), forRequest: request)
        #expect(await store.entries(forRequest: request).isEmpty)
    }
}
