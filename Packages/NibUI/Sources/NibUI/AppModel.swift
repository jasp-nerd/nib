import AppKit
import Foundation
import NibCore
import NibHTTP
import NibInterchange
import Observation

/// The root store.
///
/// Phase 1 keeps this deliberately thin: one session, one engine, no collection. Phase 3 adds the
/// collection tree and tabs, and this becomes the place selection lives.
@Observable
public final class AppModel {
    public let engine: HTTPEngine
    public var session: RequestSession
    public let collectionModel = CollectionModel()
    public let importCoordinator: ImportCoordinator

    /// Whether the Cmd-K switcher is showing.
    public var isPalettePresented = false

    /// Whether the environment editor is showing.
    public var isEnvironmentEditorPresented = false

    public init() {
        let engine = HTTPEngine()
        self.engine = engine
        importCoordinator = ImportCoordinator(collectionModel: collectionModel)
        session = RequestSession(
            spec: HTTPRequestSpec(method: .get, url: ""),
            scope: VariableScope(),
            engine: engine
        )
    }

    // MARK: - Collection

    /// Which request the session currently holds, so a redundant load can be skipped.
    private var loadedRequestID: NodeID?

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
        guard request.id != loadedRequestID else { return }

        loadedRequestID = request.id
        session.replace(with: request.spec)
        refreshScope()
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
        guard var request = collectionModel.selectedRequest else { return }
        request.spec = session.spec
        await collectionModel.update(request)
    }

    public var canSaveSelectedRequest: Bool {
        collectionModel.selectedRequest != nil
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
