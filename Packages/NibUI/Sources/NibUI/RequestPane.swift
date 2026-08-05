import NibCore
import SwiftUI

/// Method picker, URL field, Send button, and the headers/body editors.
///
/// Phase 1 is deliberately the minimum that makes the app usable end to end. The plan's richer
/// affordances — an `NSTextField` subclass with inline `{{var}}` highlighting and completion, count
/// badges, bulk edit — land alongside the collection work, once there is something to badge.
public struct RequestPane: View {
    @Bindable var session: RequestSession
    /// Bumped by ⌘L from the menu. Zero when the pane is used without a model behind it.
    var focusURLRequests = 0

    @State private var tab: Tab = .headers
    @FocusState private var urlFocused: Bool

    private enum Tab: String, CaseIterable, Identifiable {
        case params = "Params"
        case headers = "Headers"
        case body = "Body"
        case auth = "Auth"
        case settings = "Settings"
        var id: String { rawValue }
    }

    public init(session: RequestSession, focusURLRequests: Int = 0) {
        self.session = session
        self.focusURLRequests = focusURLRequests
    }

    public var body: some View {
        VStack(spacing: 0) {
            urlBar
            resolvedURL
            Divider()
            diagnostics
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(title(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .params: ParamEditor(params: $session.spec.params)
            case .headers:
                KeyValueTable(
                    rows: $session.spec.headers,
                    keyPath: \.name,
                    valuePath: \.value,
                    enabledPath: \.enabled,
                    keyPlaceholder: "Name",
                    makeRow: { HeaderField(name: $0, value: "") }
                )
            case .body: BodyEditor(spec: $session.spec.body)
            case .auth:
                AuthEditor(auth: $session.spec.auth, inherited: session.inheritedAuth)
            case .settings: SettingsEditor(settings: $session.spec.settings)
            }
        }
        .onAppear { urlFocused = true }
        .onChange(of: focusURLRequests) { urlFocused = true }
    }

    /// A count badge on the tabs that have content, so nothing is hidden behind a tab you had no
    /// reason to open. A request that mysteriously sends an extra header is usually a header you
    /// forgot about.
    private func title(for tab: Tab) -> String {
        let count: Int
        switch tab {
        case .params: count = session.spec.params.filter(\.enabled).count
        case .headers: count = session.spec.headers.filter(\.enabled).count
        case .body: count = session.spec.body == .none ? 0 : 1
        case .auth: count = session.spec.auth == .none || session.spec.auth == .inherit ? 0 : 1
        case .settings: count = 0
        }
        // A bullet rather than a number for the single-valued tabs: "Body 1" reads like a count of
        // something and invites the question "one what".
        if tab == .body || tab == .auth { return count > 0 ? "\(tab.rawValue) •" : tab.rawValue }
        return count > 0 ? "\(tab.rawValue) (\(count))" : tab.rawValue
    }

    // MARK: - URL bar

    private var urlBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $session.spec.method) {
                ForEach(HTTPMethod.common, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 96)
            .help("HTTP method")

            TextField("https://api.example.com/users", text: $session.spec.url)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($urlFocused)
                .onSubmit { session.send() }

            // No `.keyboardShortcut` here: the File menu owns Cmd-Return and Cmd-period. AppKit
            // matches menu key equivalents before the event reaches the view hierarchy, so these
            // would be dead code that drifts out of step with `validateMenuItem`.
            if session.state.isSending {
                Button("Cancel") { session.cancel() }
            } else {
                Button("Send") { session.send() }
                    .disabled(!session.canSend)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    /// What the URL becomes once variables are substituted.
    ///
    /// Only shown when it differs from what is typed, so a plain URL gets no second line. This is
    /// the whole environment feature made visible in one row: switch the picker and this changes
    /// under a URL bar that did not.
    @ViewBuilder
    private var resolvedURL: some View {
        let resolved = session.resolvedURL
        if resolved != session.spec.url, !resolved.isEmpty {
            Text(resolved)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Diagnostics
    //
    // Unresolved variables and fidelity notes appear here rather than in an alert. A request with a
    // bad variable is still sendable on purpose: seeing the server's 400 is often how you work out
    // what was wrong.

    @ViewBuilder
    private var diagnostics: some View {
        // The pre-send warning is suppressed once a send has produced its own list, so the same
        // variable is never reported twice in two slightly different wordings.
        let pending = session.unresolved.isEmpty ? session.pendingUnresolved : []

        if !session.unresolved.isEmpty || !session.notes.isEmpty || !pending.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !pending.isEmpty {
                    Label(
                        Self.describePending(pending),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                ForEach(session.unresolved, id: \.self) { item in
                    Label(
                        "{{\(item.name)}} — \(Self.describe(item.reason))",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                ForEach(session.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
        }
    }

    /// One line for all of them. A request against a fresh clone can have six unset secrets, and
    /// six stacked warning rows would push the tabs off the pane.
    private static func describePending(_ names: [String]) -> String {
        let list = names.map { "{{\($0)}}" }.joined(separator: ", ")
        return names.count == 1
            ? "\(list) is not defined in the selected environment."
            : "\(list) are not defined in the selected environment."
    }

    private static func describe(_ reason: VariableResolver.Unresolved.Reason) -> String {
        switch reason {
        case .undefined: "not defined in any environment"
        case .cycle: "refers to itself"
        case .tooDeep: "nested too deeply"
        }
    }
}
