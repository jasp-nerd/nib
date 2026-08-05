import Foundation
import NibCore

/// Sends `SendPlan`s and reports what happened.
///
/// One engine per collection, because the cookie jar is per-collection: two collections hitting
/// the same host with different sessions must not share auth cookies.
///
/// The engine never sees a `{{variable}}` — by the time a `SendPlan` exists everything is
/// resolved. That is what makes this testable against a localhost server with no store, no
/// environment and no UI in the picture.
///
/// **Not an actor.** It used to be, and that was actively misleading: both stored properties are
/// `let`, so the actor protected nothing while costing every caller an `await` and a suspension —
/// and worse, it created the impression that the engine's concurrency was handled when the real
/// shared mutable state lives on the far side of the `URLSession` delegate. That state is now
/// guarded by a `Mutex` in `EngineDelegate`, which is where the synchronisation actually belongs.
public final class HTTPEngine: @unchecked Sendable {
    private let session: URLSession

    // Deliberately strong, and there is no cycle to avoid: `EngineDelegate` holds no reference back
    // to the engine. `URLSession` retains its delegate anyway, so a weak reference here would simply
    // be a second, weaker handle on an object the session already owns -- and `send` needs it to
    // register each task.
    // swiftlint:disable:next weak_delegate
    private let delegate: EngineDelegate

    public init(ephemeral: Bool = true) {
        let configuration: URLSessionConfiguration =
            ephemeral ? .ephemeral : .default

        // Let each request's own timeout govern; the engine-level ones are a backstop.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 3600
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        // We follow redirects ourselves via the delegate so each hop can be reported.
        configuration.httpMaximumConnectionsPerHost = 6
        // Foundation adds `Accept-Encoding: gzip, deflate` and transparently decompresses.
        // Leaving that on is right for an API client -- users want the decoded body -- and the
        // fidelity notes record that it happened.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegate = EngineDelegate()
        self.delegate = delegate

        // A serial delegate queue. This is no longer what makes EngineDelegate thread-safe -- a
        // `Mutex` is, because registration happens on the caller's thread, not this queue -- but
        // serialising callbacks still keeps event ordering per task predictable and avoids
        // needless lock contention.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "app.nib.http-delegate"

        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    /// `URLSession` retains its delegate and does not deallocate until invalidated, so without this
    /// every engine leaks a session, its delegate, and an `OperationQueue` thread for the life of the
    /// process. Nothing called `cancelAll()`, so each `AppModel()` — including one per test — leaked
    /// a set.
    deinit {
        session.invalidateAndCancel()
    }

    /// Send a plan, reporting progress as a stream.
    ///
    /// The stream always terminates: with `.finished`, or `.failed`, or by the consumer breaking
    /// out of the loop (which cancels the task via `onTermination`).
    public func send(_ plan: SendPlan) -> AsyncStream<SendEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let request = Self.makeRequest(from: plan)

            let task: URLSessionTask
            if case .file(let fileURL) = plan.body {
                // Streams from disk rather than reading it in, so a large upload never counts
                // against the app's memory budget.
                task = session.uploadTask(with: request, fromFile: fileURL)
            } else {
                task = session.dataTask(with: request)
            }

            delegate.register(task: task, plan: plan, continuation: continuation)

            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }

            task.resume()
        }
    }

    /// Cancel everything in flight. Called when a collection is closed.
    public func cancelAll() {
        session.invalidateAndCancel()
    }

    // MARK: - Request construction

    static func makeRequest(from plan: SendPlan) -> URLRequest {
        var request = URLRequest(url: plan.url)
        request.httpMethod = plan.method.rawValue
        request.timeoutInterval = TimeInterval(plan.timeout.components.seconds)

        // `setValue` rather than `addValue` for the first occurrence of each name, then `addValue`
        // for repeats. URLSession comma-joins the repeats -- it cannot emit two header lines with
        // the same name -- and the delegate reports that as a fidelity note after the fact.
        var seen = Set<String>()
        for header in plan.headers {
            let key = header.name.lowercased()
            if seen.insert(key).inserted {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            } else {
                request.addValue(header.value, forHTTPHeaderField: header.name)
            }
        }

        if case .bytes(let data) = plan.body {
            request.httpBody = data
        }

        return request
    }

    /// Header fields Foundation will not send verbatim.
    ///
    /// **This list is empirical, not copied from Apple's documentation.** The documented
    /// "reserved" list is much longer and is largely obsolete: on macOS 26.5, `Host`,
    /// `Connection`, `Authorization`, `WWW-Authenticate`, `Proxy-Authorization`,
    /// `Accept-Encoding`, `User-Agent`, `Cookie` and `Referer` are all delivered exactly as set.
    /// Only these two are managed by Foundation:
    ///
    /// - `Content-Length` is always recomputed from the actual body.
    /// - `Transfer-Encoding` is dropped entirely.
    ///
    /// `HTTPEngineTests.reservedHeaderProbe` measures this against a real server and fails if the
    /// set drifts, so a future macOS change surfaces as a failing test rather than a user report.
    /// See `docs/http-fidelity.md`.
    public static let reservedHeaderFields: Set<String> = [
        "content-length",
        "transfer-encoding",
    ]

    /// Names in `headers` that Foundation will not let us send verbatim.
    public static func reservedHeaders(in headers: [SendPlan.Header]) -> [String] {
        headers.map(\.name).filter { reservedHeaderFields.contains($0.lowercased()) }
    }
}
