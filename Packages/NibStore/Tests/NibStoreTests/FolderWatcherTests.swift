import Foundation
import Testing

@testable import NibStore

/// Watching the filesystem is inherently timing-dependent, so these use a generous
/// `confirmation` timeout and assert only that the notification arrives — not how quickly.
@Suite("FolderWatcher", .serialized)
struct FolderWatcherTests {

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    /// Waits for the watcher to fire, or gives up. Polling a flag rather than using
    /// `confirmation` because the callback arrives on a `DispatchQueue`, not in a task tree.
    private func waitForFire(_ fired: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if fired() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("a file created outside the app triggers the handler")
    func detectsNewFile() async throws {
        try await withTemporaryDirectory { root in
            let flag = Flag()
            let watcher = FolderWatcher(root: root) { flag.set() }
            watcher.start()
            defer { watcher.stop() }

            // Give FSEvents a moment to arm before making the change.
            try? await Task.sleep(for: .milliseconds(200))
            try Data("{}".utf8).write(to: root.appendingPathComponent("New.req.json"))

            #expect(await waitForFire { flag.value })
        }
    }

    @Test("an edit to an existing file triggers the handler")
    func detectsEdit() async throws {
        try await withTemporaryDirectory { root in
            let file = root.appendingPathComponent("Existing.req.json")
            try Data("{}".utf8).write(to: file)

            let flag = Flag()
            let watcher = FolderWatcher(root: root) { flag.set() }
            watcher.start()
            defer { watcher.stop() }

            try? await Task.sleep(for: .milliseconds(200))
            try Data(#"{"edited":true}"#.utf8).write(to: file)

            #expect(await waitForFire { flag.value })
        }
    }

    @Test("many changes at once coalesce into few callbacks")
    func coalescesBatches() async throws {
        try await withTemporaryDirectory { root in
            let counter = Counter()
            let watcher = FolderWatcher(root: root) { counter.increment() }
            watcher.start()
            defer { watcher.stop() }

            try? await Task.sleep(for: .milliseconds(200))

            // Stand in for a `git checkout` touching a lot of files at once.
            for index in 0..<200 {
                try Data("{}".utf8).write(
                    to: root.appendingPathComponent("File\(index).req.json"))
            }

            _ = await waitForFire { counter.value > 0 }
            try? await Task.sleep(for: .milliseconds(600))

            // The point of the latency window: nowhere near one callback per file.
            #expect(counter.value < 20, "got \(counter.value) callbacks for 200 files")
        }
    }

    /// Measures callbacks *after* `stop()`, not the total.
    ///
    /// FSEvents delivers an event when the watch root is first established, so a freshly started
    /// watcher legitimately fires once before anything interesting happens. The owner has to tolerate
    /// that anyway -- it compares the store's write generation and a reload is idempotent -- but the
    /// assertion here has to be about what happens after stopping.
    @Test("no callback arrives after stopping")
    func stopEndsCallbacks() async throws {
        try await withTemporaryDirectory { root in
            let counter = Counter()
            let watcher = FolderWatcher(root: root) { counter.increment() }
            watcher.start()
            try? await Task.sleep(for: .milliseconds(300))

            watcher.stop()
            let atStop = counter.value

            try Data("{}".utf8).write(to: root.appendingPathComponent("After.req.json"))
            try? await Task.sleep(for: .milliseconds(600))

            #expect(counter.value == atStop, "fired \(counter.value - atStop) times after stop")
        }
    }

    @Test("start is idempotent")
    func doubleStartIsSafe() async throws {
        try await withTemporaryDirectory { root in
            let watcher = FolderWatcher(root: root) {}
            watcher.start()
            watcher.start()
            watcher.stop()
            watcher.stop()
        }
    }
}

/// Minimal thread-safe helpers. The callback arrives on a dispatch queue, so the test's own state
/// needs synchronising -- and a lock is cheaper than making these actors and awaiting them.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
