import Foundation
import NibCore
import NibHTTP
import Observation

/// One editable request plus whatever came back from sending it.
///
/// There is one of these per tab. It owns the send lifecycle: building the plan, streaming events,
/// and holding the result. Nothing here touches the file store — saving is Phase 3.
@Observable
public final class RequestSession: Identifiable {
    public let id = UUID()

    public var spec: HTTPRequestSpec
    public var scope: VariableScope

    /// Set while a request is in flight so the UI can show progress and offer cancel.
    public private(set) var state: State = .idle
    public private(set) var response: ResponseViewModel?
    /// Non-fatal things the builder or engine want the user to know: dropped bodies, header
    /// deviations, an insecure TLS override. Never silently discarded.
    public private(set) var notes: [String] = []
    public private(set) var unresolved: [VariableResolver.Unresolved] = []

    public enum State: Equatable {
        case idle
        case sending(received: Int64, expected: Int64?)
        case failed(String)

        public var isSending: Bool {
            if case .sending = self { return true }
            return false
        }
    }

    private let engine: HTTPEngine

    /// The in-flight send, if any.
    ///
    /// Exposed so callers can await completion deterministically -- tests do this instead of polling
    /// for a response to appear, and app teardown can await it rather than dropping a request
    /// mid-flight.
    public private(set) var inFlight: Task<Void, Never>?

    public init(
        spec: HTTPRequestSpec = HTTPRequestSpec(url: ""),
        scope: VariableScope = VariableScope(),
        engine: HTTPEngine
    ) {
        self.spec = spec
        self.scope = scope
        self.engine = engine
    }

    /// Placeholders in the URL and whether each resolves, for inline highlighting.
    public var urlPlaceholders: [VariableResolver.Placeholder] {
        VariableResolver.placeholders(in: spec.url, scope: scope)
    }

    public var canSend: Bool {
        !spec.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !state.isSending
    }

    // MARK: - Sending

    public func send() {
        guard canSend else { return }

        // Replacing an in-flight send rather than queueing: pressing Cmd-Return twice means
        // "I changed my mind", not "do it twice".
        inFlight?.cancel()

        response = nil
        notes = []
        unresolved = []

        let built: SendPlanBuilder.Output
        do {
            built = try SendPlanBuilder.build(spec, scope: scope)
        } catch {
            state = .failed(Self.describe(error))
            return
        }

        notes = built.notes
        unresolved = built.unresolved

        // Warn about reserved headers before sending, not only after. See docs/http-fidelity.md.
        let reserved = HTTPEngine.reservedHeaders(in: built.plan.headers)
        if !reserved.isEmpty {
            notes.append(
                "Foundation manages \(reserved.joined(separator: ", ")) and will not send "
                    + "your value verbatim."
            )
        }

        state = .sending(received: 0, expected: nil)
        let plan = built.plan
        let start = ContinuousClock.now

        inFlight = Task { [weak self] in
            guard let self else { return }
            for await event in engine.send(plan) {
                if Task.isCancelled { return }
                apply(event, plan: plan, start: start)
            }
        }
    }

    public func cancel() {
        inFlight?.cancel()
        inFlight = nil
        state = .idle
    }

    /// Replace this request with an imported one.
    ///
    /// Diagnostics land in `notes` so anything the importer could not represent is visible
    /// immediately, rather than discovered when the request behaves differently than the command it
    /// came from.
    public func replace(with spec: HTTPRequestSpec, notes importNotes: [String] = []) {
        cancel()
        self.spec = spec
        response = nil
        unresolved = []
        notes = importNotes
    }

    private func apply(_ event: SendEvent, plan: SendPlan, start: ContinuousClock.Instant) {
        switch event {
        case .started:
            state = .sending(received: 0, expected: nil)

        case .bodyChunk(let received, let expected):
            state = .sending(received: received, expected: expected)

        case .responseHead, .redirected:
            break  // Reflected in the final result; no interim UI for these yet.

        case .finished(let result):
            state = .idle
            notes.append(contentsOf: result.fidelityNotes)
            response = ResponseViewModel(result: result, requestURL: plan.url)

        case .failed(let failure):
            state = .failed(failure.message)
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let build = error as? SendPlanBuilder.BuildError else {
            return error.localizedDescription
        }
        switch build {
        case .emptyURL:
            return "Enter a URL."
        case .invalidURL(let value):
            return "That URL could not be parsed: \(value)"
        case .unsupportedBody(let reason):
            return reason
        }
    }
}
