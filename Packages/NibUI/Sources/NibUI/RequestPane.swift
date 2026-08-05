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

    /// The blank row's text. Real `@State`, not a `Binding` whose getter always returns `""` — that
    /// trick drove the field back to empty after each committed keystroke, so typing "abc" produced
    /// either three one-character rows or one row plus stray text, depending on when AppKit
    /// re-read the getter.
    @State private var draftName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Positional identity. `HeaderField` has no id (see its doc comment for why adding
                // one was rejected), so a delete does shift identity and can move focus to the
                // adjacent row. The removal itself is deferred below, which is what keeps it from
                // committing an edit through a stale binding.
                ForEach(headers.indices, id: \.self) { index in
                    row(index: index)
                    Divider()
                }
                blankRow
            }
        }
    }

    private func row(index: Int) -> some View {
        HStack(spacing: 8) {
            Toggle("Include this header", isOn: $headers[index].enabled)
                .labelsHidden()
                .help("Include this header")
            TextField("Name", text: $headers[index].name)
            TextField("Value", text: $headers[index].value)
            Button("Remove header", systemImage: "minus.circle") {
                remove(at: index)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(headers[index].enabled ? 1 : 0.5)
    }

    /// Remove on the next runloop pass rather than during the current view update.
    ///
    /// Mutating the array while a focused `TextField` in a later row still holds a binding to its old
    /// index is the shape that commits an edit through a stale index — out of bounds if the row was
    /// the last one. Deferring lets the field give up focus first.
    private func remove(at index: Int) {
        DispatchQueue.main.async {
            guard headers.indices.contains(index) else { return }
            headers.remove(at: index)
        }
    }

    /// Typing anything here materialises a real row, so adding a header never needs a button.
    private var blankRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
            TextField("Name", text: $draftName)
                .onChange(of: draftName) {
                    guard !draftName.isEmpty else { return }
                    headers.append(HeaderField(name: draftName, value: ""))
                    draftName = ""
                }
            Spacer()
            // Fixed-width spacer rather than a hidden image: an invisible-but-hittable control is a
            // VoiceOver artefact.
            Color.clear.frame(width: 20, height: 1)
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Body editor

/// The raw-body editor.
///
/// The text is projected straight out of `spec` rather than mirrored into `@State`. The mirrored
/// version seeded itself in `onAppear` only, so any external change to the request left it stale —
/// and that was reachable in normal use: pasting a cURL command sets a `--data-raw` body, `onAppear`
/// had already fired, so the body never appeared and the next keystroke wrote the stale empty value
/// back over the imported one.
///
/// `language` stays in `@State` because it is a UI preference that has to survive the body being
/// emptied (which collapses `spec` to `.none`, taking any stored language with it). It is re-synced
/// whenever `spec` arrives carrying one.
struct BodyEditor: View {
    // Named `spec`, not `body` -- a stored property called `body` collides with the View
    // requirement and the error message ("invalid redeclaration") does not say why.
    @Binding var spec: BodySpec

    @State private var language: BodySpec.RawLanguage = .json

    private var text: Binding<String> {
        Binding(
            get: {
                if case .raw(let existing, _) = spec { return existing }
                return ""
            },
            set: { spec = $0.isEmpty ? .none : .raw(text: $0, language: language) }
        )
    }

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
                Button("Clear") { spec = .none }
                    .disabled(text.wrappedValue.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
        }
        .onChange(of: language) {
            // Re-tag an existing body with the newly chosen language, without discarding it.
            if case .raw(let existing, _) = spec, !existing.isEmpty {
                spec = .raw(text: existing, language: language)
            }
        }
        .onChange(of: spec, initial: true) {
            // Follow an externally-supplied body, e.g. a cURL import.
            if case .raw(_, let incoming) = spec, incoming != language {
                language = incoming
            }
        }
    }
}
