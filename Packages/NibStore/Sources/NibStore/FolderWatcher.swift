import Foundation

/// Watches a collection folder for changes made outside the app.
///
/// This is what makes "these are your files" real rather than a claim: edit a request in vim, or
/// `git checkout` a branch, and the sidebar follows.
///
/// **FSEvents, not a timer.** `AGENTS.md` bans polling timers and `Tools/check-boundaries.sh`
/// enforces it, because a repeating timer keeps the CPU out of idle and is the single most likely way
/// this app stops being able to claim 0% idle CPU. FSEvents is push-based: the process sleeps until
/// the kernel has something to say.
///
/// Three behaviours that matter more than the plumbing:
///
///   - **Coalescing.** A `git checkout` touches hundreds of files. FSEvents' latency window batches
///     them, so the callback fires once per batch rather than once per file.
///   - **Ignoring our own writes.** `CollectionStore` bumps a generation on every save; the owner
///     compares it before reloading. Without that, saving would trigger a reload of the tree we just
///     wrote, and a reload mid-edit would discard whatever the user typed next.
///   - **Nothing fires after `stop()`.** See the note on teardown below; getting this wrong is a
///     use-after-free, not just a stray notification.
public final class FolderWatcher: @unchecked Sendable {

    /// Called on `queue` after a batch of changes.
    public typealias Handler = @Sendable () -> Void

    private let root: URL
    private let handler: Handler
    private let queue: DispatchQueue

    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    /// Checked inside the callback. FSEvents can have a callback already queued when `stop()` runs,
    /// and delivering it would tell the owner to reload a collection it has just closed.
    private var isStopped = false

    /// FSEvents' coalescing window. 200 ms is long enough to collapse a `git checkout` into one
    /// callback and short enough that an editor save feels immediate.
    private let latency: CFTimeInterval = 0.2

    public init(
        root: URL,
        queue: DispatchQueue = DispatchQueue(label: "app.nib.folder-watcher"),
        handler: @escaping Handler
    ) {
        self.root = root
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        guard stream == nil, !isStopped else {
            lock.unlock()
            return
        }
        lock.unlock()

        // The callback is C, so it gets an opaque pointer to self. The matching release happens in
        // `stop()`, deferred onto `queue` -- see the comment there.
        let info = Unmanaged.passRetained(self).toOpaque()

        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.deliver()
        }

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                // FileEvents gives per-file rather than per-directory granularity; WatchRoot reports
                // the folder itself being moved or renamed, which would otherwise look like every
                // file vanishing at once.
                UInt32(
                    kFSEventStreamCreateFlagUseCFTypes
                        | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagWatchRoot
                        | kFSEventStreamCreateFlagNoDefer)
            )
        else {
            // The stream never took ownership, so balance the retain immediately.
            Unmanaged<FolderWatcher>.fromOpaque(info).release()
            return
        }

        lock.lock()
        stream = created
        lock.unlock()

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    /// Stop watching. Safe to call more than once, and safe to call from `deinit`.
    public func stop() {
        lock.lock()
        guard let stream else {
            isStopped = true
            lock.unlock()
            return
        }
        isStopped = true
        self.stream = nil
        lock.unlock()

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        // Release the retain *on the watcher's own serial queue*, after anything already queued.
        //
        // Invalidate promises no new callbacks, but one dispatched a moment earlier may still be
        // waiting on the queue. Releasing here on the calling thread could therefore drop the last
        // reference while that callback is about to run, which is a use-after-free. Hopping onto the
        // serial queue orders the release behind any pending delivery.
        //
        // Deliberately captures the pointer's bit pattern, not `self`: this runs from `deinit`,
        // where capturing `self` in an escaping closure is not allowed. A `UInt` rather than the
        // pointer itself because `UnsafeMutableRawPointer` is not `Sendable`, and reconstructing it
        // inside the closure is exactly as safe while keeping the concurrency checker satisfied.
        let address = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        queue.async {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<FolderWatcher>.fromOpaque(pointer).release()
        }
    }

    private func deliver() {
        lock.lock()
        let stopped = isStopped
        lock.unlock()

        guard !stopped else { return }
        handler()
    }
}
