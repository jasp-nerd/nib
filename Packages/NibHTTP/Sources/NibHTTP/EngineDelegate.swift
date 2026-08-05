import Foundation
import NibCore
import Synchronization

/// URLSession delegate for all in-flight requests.
///
/// **Concurrency model: a `Mutex`, not queue confinement.**
///
/// An earlier version claimed all mutable state was touched only from the serial `delegateQueue`,
/// and that was false. `register(task:plan:continuation:)` is called from `HTTPEngine.send`, because
/// `AsyncStream`'s build closure is non-escaping and runs *synchronously inside the initialiser* —
/// so registration mutates `states` on the caller's thread while other in-flight tasks' callbacks
/// mutate the same `Dictionary` on the delegate queue. Unsynchronised `Dictionary` mutation from two
/// threads is memory corruption, not a stale read.
///
/// It was reachable in the shipping app, not hypothetical: `RequestSession.send()` cancels the
/// previous task and immediately builds a new stream, so the old task's `didCompleteWithError`
/// (`removeValue`) races the new `register` (insert).
///
/// Hopping `register` onto the delegate queue is *not* the fix — it would either block the caller or
/// let `task.resume()` outrun the registration. A lock is.
///
/// `Synchronization.Mutex` is in the standard library, so this adds no dependency.
final class EngineDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private struct TaskState {
        let plan: SendPlan
        let continuation: AsyncStream<SendEvent>.Continuation
        let sink = ResponseSink()
        let start: ContinuousClock.Instant
        var head: SendEvent.ResponseHead?
        var hops: [SendEvent.Hop] = []
        var fidelityNotes: [String] = []
        var networkProtocol: String?
        var timing: SendEvent.Timing?
    }

    /// Guarded by a mutex; see the type doc for why queue confinement was not enough.
    private let states = Mutex<[Int: TaskState]>([:])

    // MARK: - Registration

    /// Called from the engine actor before `task.resume()`. Safe because the task cannot produce
    /// callbacks until it is resumed.
    func register(
        task: URLSessionTask,
        plan: SendPlan,
        continuation: AsyncStream<SendEvent>.Continuation
    ) {
        states.withLock {
            $0[task.taskIdentifier] = TaskState(
                plan: plan,
                continuation: continuation,
                start: ContinuousClock.now
            )
        }
        continuation.yield(.started)
    }

    // MARK: - Response head

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }

        let expected =
            response.expectedContentLength == NSURLSessionTransferSizeUnknown
            ? nil : response.expectedContentLength

        let head = SendEvent.ResponseHead(
            status: http.statusCode,
            headers: http.allHeaderFields.compactMap { key, value in
                guard let name = key as? String else { return nil }
                return SendPlan.Header(name: name, value: String(describing: value))
            },
            expectedLength: expected
        )

        let continuation = states.withLock { table -> AsyncStream<SendEvent>.Continuation? in
            guard var state = table[dataTask.taskIdentifier] else { return nil }
            state.head = head
            table[dataTask.taskIdentifier] = state
            return state.continuation
        }
        continuation?.yield(.responseHead(head))
        completionHandler(.allow)
    }

    // MARK: - Body

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let event = states.withLock { table -> (AsyncStream<SendEvent>.Continuation, SendEvent)? in
            guard let state = table[dataTask.taskIdentifier] else { return nil }
            state.sink.append(data)
            return (
                state.continuation,
                .bodyChunk(received: state.sink.byteCount, expected: state.head?.expectedLength)
            )
        }
        if let event { event.0.yield(event.1) }
    }

    // MARK: - Redirects

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // All state work happens inside the lock; yielding and calling the completion handler happen
        // outside it, so a consumer resuming on another thread can never re-enter the lock.
        enum Decision {
            case passThrough
            case stop(AsyncStream<SendEvent>.Continuation, SendEvent)
            case follow(AsyncStream<SendEvent>.Continuation, SendEvent, URLRequest)
        }

        let decision = states.withLock { table -> Decision in
            guard var state = table[task.taskIdentifier] else { return .passThrough }

            let from = response.url ?? state.plan.url
            let to = request.url ?? from
            let hop = SendEvent.Hop(from: from, to: to, status: response.statusCode)
            state.hops.append(hop)

            guard state.plan.redirects.follow else {
                table[task.taskIdentifier] = state
                // Stopping here delivers the 3xx itself, which is what someone who turned redirects
                // off wants to see.
                return .stop(state.continuation, .redirected(hop))
            }

            guard state.hops.count <= state.plan.redirects.maximum else {
                table[task.taskIdentifier] = state
                return .stop(
                    state.continuation,
                    .failed(
                        SendEvent.Failure(
                            kind: .tooManyRedirects,
                            message:
                                "Stopped after \(state.plan.redirects.maximum) redirects. "
                                + "Raise the limit in request settings if this is expected."
                        )))
            }

            var next = request
            if let note = applyMethodPreference(
                to: &next, plan: state.plan, statusCode: response.statusCode)
            {
                state.fidelityNotes.append(note)
            }

            table[task.taskIdentifier] = state
            return .follow(state.continuation, .redirected(hop), next)
        }

        switch decision {
        case .passThrough:
            completionHandler(request)
        case .stop(let continuation, let event):
            continuation.yield(event)
            completionHandler(nil)
        case .follow(let continuation, let event, let next):
            continuation.yield(event)
            completionHandler(next)
        }
    }

    /// Decide what to do about URLSession rewriting the method across a 301/302/303.
    ///
    /// URLSession changes the method to GET and drops the body, matching browsers. curl's
    /// `--location -X POST` does not. Neither is wrong, so it is a per-request setting -- but the
    /// deviation is recorded either way, so the timing panel can explain why the second hop was a GET.
    ///
    /// Returns a fidelity note to record, or `nil` when nothing was rewritten.
    private func applyMethodPreference(
        to request: inout URLRequest,
        plan: SendPlan,
        statusCode: Int
    ) -> String? {
        let rewritten = statusCode == 301 || statusCode == 302 || statusCode == 303
        guard rewritten, plan.method.rawValue != request.httpMethod else { return nil }

        guard plan.redirects.preserveMethod else {
            return "URLSession changed \(plan.method) to GET on the \(statusCode) redirect and "
                + "dropped the body. Enable \"Preserve method on redirect\" to keep it."
        }

        request.httpMethod = plan.method.rawValue
        if case .bytes(let data) = plan.body {
            request.httpBody = data
        }
        return "Re-applied \(plan.method) across the \(statusCode) redirect "
            + "(URLSession would have used GET)."
    }

    // MARK: - TLS

    /// The **task-scoped** challenge handler.
    ///
    /// Task-scoped rather than session-scoped on purpose: it hands us the `URLSessionTask`, so the
    /// per-request TLS policy can be looked up exactly. The session-level variant carries no task,
    /// which previously forced a guess across every in-flight request.
    ///
    /// IMPORTANT: do not evaluate the trust ourselves.
    ///
    /// An earlier version called `SecTrustEvaluateWithError` here and sent
    /// `.cancelAuthenticationChallenge` when it returned false. That broke every HTTPS request
    /// against servers whose evaluation needs more than the bare trust object — most commonly one
    /// that does not send its full certificate chain, where the intermediate has to be fetched.
    /// URLSession's own default handling does that fetching, plus revocation checking and ATS
    /// policy; a hand-rolled `SecTrustEvaluateWithError` does none of it and fails valid servers.
    ///
    /// So: verification on means `.performDefaultHandling` and let the system decide. A genuinely
    /// bad certificate then fails the task with a real `URLError`, which `failure(from:)` already
    /// maps to `.tlsUntrusted` with a usable message.
    ///
    /// The localhost test suite could never have caught this — `TestHTTPServer` speaks plain HTTP,
    /// so no test triggered a TLS challenge at all. `LiveNetworkTests` now covers it.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // Only server trust is handled. Client certificates are out of scope for v1.
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let verify = states.withLock({ $0[task.taskIdentifier]?.plan.tls.verify })
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if verify {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Only ever reached when the user explicitly turned verification off for this request.
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    // MARK: - Metrics

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last else { return }

        // Microseconds, not milliseconds. A loopback request completes in well under 1 ms, and
        // millisecond granularity truncated the whole timing breakdown to zero -- which looked
        // like "no timing data" rather than "very fast".
        func gap(_ from: Date?, _ to: Date?) -> Duration? {
            guard let from, let to else { return nil }
            return .microseconds(Int(to.timeIntervalSince(from) * 1_000_000))
        }

        let networkProtocol = transaction.networkProtocolName
        let timing = SendEvent.Timing(
            dns: gap(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: gap(transaction.connectStartDate, transaction.connectEndDate),
            tls: gap(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            request: gap(transaction.requestStartDate, transaction.requestEndDate),
            timeToFirstByte: gap(transaction.requestEndDate, transaction.responseStartDate),
            download: gap(transaction.responseStartDate, transaction.responseEndDate),
            total: .microseconds(Int(metrics.taskInterval.duration * 1_000_000))
        )

        let sent = task.currentRequest?.allHTTPHeaderFields

        states.withLock { table in
            guard var state = table[task.taskIdentifier] else { return }
            state.networkProtocol = networkProtocol
            state.timing = timing

            // Compare what we asked to send against what actually went on the wire. This is the
            // programmatic version of the fidelity spike: Foundation reserves a couple of header
            // fields and comma-joins duplicates, and the honest thing is to report it rather than
            // pretend the request went out verbatim.
            if let sent {
                for header in state.plan.headers {
                    guard let actual = sent[header.name] ?? sent[header.name.capitalized] else {
                        state.fidelityNotes.append(
                            "Header \"\(header.name)\" was not sent: Foundation reserves this "
                                + "field and sets it itself."
                        )
                        continue
                    }
                    if actual != header.value, actual.contains(header.value) {
                        state.fidelityNotes.append(
                            "Header \"\(header.name)\" was combined into a single line: "
                                + "\"\(actual)\". URLSession cannot emit repeated header fields."
                        )
                    }
                }
            }

            table[task.taskIdentifier] = state
        }
    }

    // MARK: - Completion

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let state = states.withLock({ $0.removeValue(forKey: task.taskIdentifier) })
        else { return }

        if let error {
            state.sink.discard()
            state.continuation.yield(.failed(Self.failure(from: error)))
            state.continuation.finish()
            return
        }

        guard let head = state.head else {
            state.sink.discard()
            state.continuation.yield(
                .failed(
                    SendEvent.Failure(kind: .other(code: 0), message: "No response was received.")))
            state.continuation.finish()
            return
        }

        var notes = state.fidelityNotes
        if let spillFailure = state.sink.spillFailure {
            notes.append(spillFailure)
        }

        let elapsed = ContinuousClock.now - state.start
        let result = SendEvent.Result(
            head: head,
            payload: state.sink.finish(),
            timing: state.timing
                ?? SendEvent.Timing(
                    total: .milliseconds(
                        Int(
                            Double(elapsed.components.seconds) * 1000
                                + Double(elapsed.components.attoseconds) / 1e15))),
            hops: state.hops,
            networkProtocol: state.networkProtocol,
            fidelityNotes: notes
        )

        state.continuation.yield(.finished(result))
        state.continuation.finish()
    }
}
