import AppKit
import Foundation
import NibCore
import NibHTTP
import NibInterchange
import NibStore
import Observation

/// The root store.
///
/// Phase 1 keeps this deliberately thin: one session, one engine, no collection. Phase 3 adds the
/// collection tree and tabs, and this becomes the place selection lives.
@Observable
public final class AppModel {
    public let engine: HTTPEngine
    public let collectionModel = CollectionModel()
    public let importCoordinator: ImportCoordinator

    /// Open tabs, in strip order. Never empty — closing the last one opens a fresh one, because a
    /// window with no request in it has nothing to show and no way back.
    public private(set) var tabs: [RequestSession] = []
    public private(set) var activeTabID: UUID = UUID()

    /// The tab everything else means when it says "the request".
    ///
    /// Computed rather than stored so there is exactly one source of truth. A stored `session`
    /// alongside `tabs` is two places to update and one of them will be missed.
    public var session: RequestSession {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    /// Whether the Cmd-K switcher is showing.
    public var isPalettePresented = false

    /// Whether the environment editor is showing.
    public var isEnvironmentEditorPresented = false

    /// Incremented by ⌘L. A counter rather than a flag because the same request can be made twice
    /// in a row, and a flag that is already `true` produces no change for the view to observe.
    public var focusURLRequests = 0

    /// Past responses for the selected request, newest first.
    public private(set) var history: [HistoryStore.Entry] = []

    private let historyStore: HistoryStore?

    public init() {
        let engine = HTTPEngine()
        self.engine = engine
        importCoordinator = ImportCoordinator(collectionModel: collectionModel)
        // Optional rather than fatal: a machine where Application Support cannot be created still
        // gets a working API client, just without history.
        historyStore = try? HistoryStore()

        let first = RequestSession(
            spec: HTTPRequestSpec(method: .get, url: ""),
            scope: VariableScope(),
            engine: engine
        )
        tabs = [first]
        activeTabID = first.id
        adopt(first)
    }

    // MARK: - Tabs

    /// Wire a session up to the model. Every tab needs this, so it lives in one place rather than
    /// being repeated at each creation site — a tab that quietly records no history because
    /// somebody forgot a line is exactly the kind of bug that survives review.
    private func adopt(_ tab: RequestSession) {
        tab.onFinished = { [weak self, weak tab] result, plan in
            guard let self, let tab, tab.id == activeTabID else { return }
            recordInHistory(result, plan: plan)
        }
    }

    @discardableResult
    public func newTab() -> RequestSession {
        let tab = RequestSession(
            spec: HTTPRequestSpec(method: .get, url: ""), scope: VariableScope(), engine: engine)
        adopt(tab)
        tabs.append(tab)
        select(tab.id)
        return tab
    }

    public func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        Task { await reloadHistory() }
    }

    /// Close a tab, keeping the selection somewhere sensible.
    ///
    /// Closing the active tab moves to its neighbour rather than to the first tab, which is what
    /// every editor does and what the muscle memory expects.
    public func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }

        // An in-flight request in a closed tab has nowhere to deliver its response.
        tabs[index].cancel()
        tabs.remove(at: index)

        if tabs.isEmpty {
            newTab()
            return
        }
        if activeTabID == id {
            select(tabs[min(index, tabs.count - 1)].id)
        }
    }

    public func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    public func selectNextTab(by offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == activeTabID }), tabs.count > 1 else {
            return
        }
        // Wrapping, so Cmd-Shift-] on the last tab goes back to the first.
        let next = (current + offset + tabs.count) % tabs.count
        select(tabs[next].id)
    }

    public var canCloseTab: Bool { tabs.count > 1 }

    // MARK: - History

    /// File a completed response against the request that produced it.
    ///
    /// Only for saved requests. An unsaved scratch request has no stable id, so there would be
    /// nothing to file it under and nothing to prune it with later.
    private func recordInHistory(_ result: SendEvent.Result, plan: SendPlan) {
        guard let historyStore, let requestID = session.loadedRequestID,
            let response = session.response
        else { return }

        let preview = String(response.bodyText.prefix(HistoryStore.bodyPreviewLimit))
        let entry = HistoryStore.Entry(
            id: NodeID.generate().rawValue,
            date: Date(),
            method: plan.method.rawValue,
            url: plan.url.absoluteString,
            status: result.head.status,
            durationMilliseconds: Double(result.timing.total.components.seconds) * 1000
                + Double(result.timing.total.components.attoseconds) / 1e15,
            byteCount: response.byteCount,
            bodyPreview: preview,
            isBodyTruncated: preview.count < response.bodyText.count || response.isTruncated)

        Task { [weak self] in
            await historyStore.record(entry, forRequest: requestID)
            await self?.reloadHistory()
        }
    }

    public func reloadHistory() async {
        guard let historyStore, let requestID = session.loadedRequestID else {
            history = []
            return
        }
        history = await historyStore.entries(forRequest: requestID)
    }

    /// Drop history belonging to requests that have been deleted.
    ///
    /// Runs after a collection loads rather than at delete time, so it also cleans up after a
    /// request removed in Finder or on another machine.
    public func pruneHistory() async {
        guard let historyStore, let collection = collectionModel.collection else { return }
        await historyStore.prune(keeping: Set(collection.allRequests.map(\.request.id)))
    }

    // MARK: - Collection

    /// Load the selected request into the editing session.
    ///
    /// The session is edited in place rather than replaced, because the panes captured the object once
    /// -- replacing it would leave them showing the old one.
    ///
    /// Idempotent, and that is load-bearing rather than tidiness. `SidebarContent` calls this from an
    /// `onChange`, so SwiftUI can deliver it a moment *after* something else has already loaded the
    /// same request and started a send -- and `replace(with:)` calls `cancel()`, which would kill the
    /// in-flight request and blank the response. Symptom: a request that fires and silently produces
    /// nothing. Comparing the id first makes the redundant call free.
    public func loadSelectedRequest() {
        guard let request = collectionModel.selectedRequest else { return }
        // Per tab, not per model: two tabs can legitimately hold the same request, and a shared
        // latch would stop the second one ever loading it.
        guard request.id != session.loadedRequestID else { return }

        session.loadedRequestID = request.id
        session.replace(with: request.spec)
        refreshScope()
        Task { await reloadHistory() }
    }

    /// Re-resolve the current request against the collection as it stands now.
    ///
    /// Separate from `loadSelectedRequest` because the two have opposite conditions: loading is
    /// skipped when the request has not changed, and this is called precisely when it has *not* —
    /// the environment was switched, or a variable's value was edited. Folding it into the load
    /// path would mean flipping Local to Staging did nothing until you clicked away and back.
    public func refreshScope() {
        guard let id = collectionModel.selectedRequestID else { return }
        session.scope = collectionModel.scope(forRequestWithID: id)
        session.inheritedAuth = collectionModel.inheritedAuth(forRequestWithID: id)
    }

    /// Write the edited request back to disk.
    public func saveSelectedRequest() async {
        guard let id = session.loadedRequestID,
            var request = collectionModel.collection?.request(withID: id)
        else { return }
        request.spec = session.spec
        await collectionModel.update(request)
    }

    public var canSaveSelectedRequest: Bool {
        session.loadedRequestID != nil
    }

    /// Wired to Cmd-Return from the menu, so it works from any focused field.
    public func sendCurrentRequest() {
        session.send()
    }

    public func cancelCurrentRequest() {
        session.cancel()
    }

    // MARK: - cURL interchange

    /// Whether the clipboard currently holds something we could import.
    ///
    /// Used to enable or disable the menu item, so `⌥⌘V` is never offered when it would only produce
    /// an error.
    public var clipboardHoldsCurlCommand: Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        return CurlImporter.looksLikeCurl(text)
    }

    /// Replace the current request with a cURL command from the clipboard.
    ///
    /// Returns a message to show on failure, or `nil` on success. Failures are expected here — people
    /// paste all sorts of things — so this is a normal outcome to report, not an error to throw.
    @discardableResult
    public func pasteCurlFromClipboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "The clipboard is empty."
        }

        do {
            let parsed = try CurlImporter.parse(text)
            session.replace(
                with: parsed.spec,
                notes: parsed.diagnostics.map(\.message)
            )
            return nil
        } catch let error as ShellLexer.LexError {
            return Self.describe(error)
        } catch let error as ImportError {
            return Self.describe(error)
        } catch {
            return error.localizedDescription
        }
    }

    /// Copy the current request as a cURL command.
    ///
    /// Returns a message on failure, `nil` on success.
    @discardableResult
    public func copyAsCurl(redacted: Bool) -> String? {
        do {
            let command = try CurlExporter.export(
                session.spec,
                scope: session.scope,
                style: redacted ? .redacted : .plain
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            return nil
        } catch let error as SendPlanBuilder.BuildError {
            if case .emptyURL = error { return "Enter a URL first." }
            return "Could not build the request: \(error)"
        } catch {
            return error.localizedDescription
        }
    }

    private static func describe(_ error: ShellLexer.LexError) -> String {
        switch error {
        case .unterminatedQuote(let character):
            "The command has an unclosed \(character) quote."
        case .unsupportedShellSyntax(let reason):
            reason
        }
    }

    private static func describe(_ error: ImportError) -> String {
        switch error {
        case .unrecognisedFormat:
            "That does not look like a cURL command."
        case .malformed(let reason):
            reason
        case .unsupportedVersion(let version):
            "Unsupported format version: \(version)"
        }
    }
}
