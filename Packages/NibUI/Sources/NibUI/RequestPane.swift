import NibCore
import SwiftUI

/// Method picker, URL field, Send button, and the headers/body editors.
///
/// Phase 1 is deliberately the minimum that makes the app usable end to end. The plan's richer
/// affordances — an `NSTextField` subclass with inline `{{var}}` highlighting and completion, count
/// badges, bulk edit — land alongside the collection work, once there is something to badge.
public struct RequestPane: View {
    @Bindable var session: RequestSession

    @State private var tab: Tab = .headers
    @FocusState private var urlFocused: Bool

    private enum Tab: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case body = "Body"
        var id: String { rawValue }
    }

    public init(session: RequestSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            urlBar
            Divider()
            diagnostics
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            switch tab {
            case .headers: HeaderTable(headers: $session.spec.headers)
            case .body: BodyEditor(spec: $session.spec.body)
            }
        }
        .onAppear { urlFocused = true }
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

            if session.state.isSending {
                Button("Cancel") { session.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send") { session.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!session.canSend)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }

    // MARK: - Diagnostics
    //
    // Unresolved variables and fidelity notes appear here rather than in an alert. A request with a
    // bad variable is still sendable on purpose: seeing the server's 400 is often how you work out
    // what was wrong.

    @ViewBuilder
    private var diagnostics: some View {
        if !session.unresolved.isEmpty || !session.notes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
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

    private static func describe(_ reason: VariableResolver.Unresolved.Reason) -> String {
        switch reason {
        case .undefined: "not defined in any environment"
        case .cycle: "refers to itself"
        case .tooDeep: "nested too deeply"
        }
    }
}

// MARK: - Header table

/// A key/value table with the behaviours everyone expects from Postman: a permanently blank
/// trailing row that becomes real when typed into, and a per-row enable checkbox that keeps the
/// value when unticked.
struct HeaderTable: View {
    @Binding var headers: [HeaderField]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, _ in
                    row(index: index)
                    Divider()
                }
                blankRow
            }
        }
    }

    private func row(index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $headers[index].enabled)
                .labelsHidden()
                .help("Include this header")
            TextField("Name", text: $headers[index].name)
            TextField("Value", text: $headers[index].value)
            Button {
                headers.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(headers[index].enabled ? 1 : 0.5)
    }

    /// Typing anything here materialises a real row, so adding a header never needs a button.
    private var blankRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
            TextField(
                "Name",
                text: Binding(
                    get: { "" },
                    set: { newValue in
                        guard !newValue.isEmpty else { return }
                        headers.append(HeaderField(name: newValue, value: ""))
                    })
            )
            Text("").frame(maxWidth: .infinity)
            Image(systemName: "minus.circle").opacity(0)
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Body editor

struct BodyEditor: View {
    // Named `spec`, not `body` -- a stored property called `body` collides with the View
    // requirement and the error message ("invalid redeclaration") does not say why.
    @Binding var spec: BodySpec

    @State private var text: String = ""
    @State private var language: BodySpec.RawLanguage = .json

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Body", selection: $language) {
                    ForEach(BodySpec.RawLanguage.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .frame(width: 200)
                Spacer()
                Button("Clear") {
                    text = ""
                    syncUp()
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .onChange(of: text) { syncUp() }
                .onChange(of: language) { syncUp() }
        }
        .onAppear {
            if case .raw(let existing, let existingLanguage) = spec {
                text = existing
                language = existingLanguage
            }
        }
    }

    private func syncUp() {
        spec = text.isEmpty ? .none : .raw(text: text, language: language)
    }
}
