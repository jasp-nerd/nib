import AppKit
import NibCore
import SwiftUI

/// The body editor: a type picker and whichever editor that type needs.
///
/// Switching type keeps what was there — flipping to Form and back must not empty a raw body you
/// spent five minutes on. The previous value is held per kind in `@State` and restored, which is
/// the one place mirroring model state into view state is right, because the model deliberately
/// cannot represent "a raw body I am not currently using".
struct BodyEditor: View {
    // Named `spec`, not `body` -- a stored property called `body` collides with the View
    // requirement and the error message ("invalid redeclaration") does not say why.
    @Binding var spec: BodySpec

    @State private var remembered: [BodyKind: BodySpec] = [:]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: kind) {
                    ForEach(BodyKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)

                if case .raw(_, let language) = spec {
                    Picker("", selection: rawLanguage) {
                        ForEach(BodySpec.RawLanguage.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .help("Sets the Content-Type: \(language.contentType)")
                }

                Spacer()

                if spec != .none {
                    Button("Clear") { setKind(.none) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
            editor
        }
        .onChange(of: spec, initial: true) {
            remembered[BodyKind(spec)] = spec
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch spec {
        case .none:
            EmptyBodyView()
        case .raw:
            RawBodyEditor(text: rawText)
        case .urlEncoded:
            KeyValueTable(
                rows: urlEncodedFields,
                keyPath: \.name,
                valuePath: \.value,
                enabledPath: \.enabled,
                keyPlaceholder: "Field",
                makeRow: { Param(kind: .query, name: $0, value: "") }
            )
        case .multipart:
            MultipartEditor(parts: multipartParts)
        case .graphQL:
            GraphQLEditor(query: graphQLQuery, variables: graphQLVariables)
        case .binary:
            BinaryBodyEditor(path: binaryPath)
        }
    }

    // MARK: - Kind

    private var kind: Binding<BodyKind> {
        Binding(get: { BodyKind(spec) }, set: { setKind($0) })
    }

    private func setKind(_ new: BodyKind) {
        guard new != BodyKind(spec) else { return }
        spec = remembered[new] ?? new.empty
    }

    // MARK: - Per-kind bindings

    private var rawText: Binding<String> {
        Binding(
            get: {
                guard case .raw(let text, _) = spec else { return "" }
                return text
            },
            set: { spec = .raw(text: $0, language: rawLanguage.wrappedValue) })
    }

    private var rawLanguage: Binding<BodySpec.RawLanguage> {
        Binding(
            get: {
                guard case .raw(_, let language) = spec else { return .json }
                return language
            },
            set: { spec = .raw(text: rawText.wrappedValue, language: $0) })
    }

    private var urlEncodedFields: Binding<[Param]> {
        Binding(
            get: {
                guard case .urlEncoded(let fields) = spec else { return [] }
                return fields
            },
            set: { spec = .urlEncoded($0) })
    }

    private var multipartParts: Binding<[MultipartPart]> {
        Binding(
            get: {
                guard case .multipart(let parts) = spec else { return [] }
                return parts
            },
            set: { spec = .multipart($0) })
    }

    private var graphQLQuery: Binding<String> {
        Binding(
            get: {
                guard case .graphQL(let query, _) = spec else { return "" }
                return query
            },
            set: { spec = .graphQL(query: $0, variables: graphQLVariables.wrappedValue) })
    }

    private var graphQLVariables: Binding<String> {
        Binding(
            get: {
                guard case .graphQL(_, let vars) = spec else { return "" }
                return vars
            },
            set: { spec = .graphQL(query: graphQLQuery.wrappedValue, variables: $0) })
    }

    private var binaryPath: Binding<String> {
        Binding(
            get: {
                guard case .binary(let path) = spec else { return "" }
                return path
            },
            set: { spec = .binary(path: $0) })
    }
}

enum BodyKind: String, CaseIterable, Identifiable, Hashable {
    case none, raw, urlEncoded, multipart, graphQL, binary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No body"
        case .raw: "Raw"
        case .urlEncoded: "Form URL-encoded"
        case .multipart: "Form data"
        case .graphQL: "GraphQL"
        case .binary: "Binary file"
        }
    }

    init(_ spec: BodySpec) {
        switch spec {
        case .none: self = .none
        case .raw: self = .raw
        case .urlEncoded: self = .urlEncoded
        case .multipart: self = .multipart
        case .graphQL: self = .graphQL
        case .binary: self = .binary
        }
    }

    var empty: BodySpec {
        switch self {
        case .none: .none
        case .raw: .raw(text: "", language: .json)
        case .urlEncoded: .urlEncoded([])
        case .multipart: .multipart([])
        case .graphQL: .graphQL(query: "", variables: "")
        case .binary: .binary(path: "")
        }
    }
}

// MARK: - Editors

private struct EmptyBodyView: View {
    var body: some View {
        Text("This request sends no body.")
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The text is projected straight out of `spec` rather than mirrored into `@State`.
///
/// The mirrored version seeded itself in `onAppear` only, so any external change left it stale —
/// and that was reachable in normal use: pasting a cURL command sets a `--data-raw` body, `onAppear`
/// had already fired, so the body never appeared and the next keystroke wrote the stale empty value
/// back over the imported one.
private struct RawBodyEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
    }
}

/// `multipart/form-data`: text fields and file attachments in one list.
private struct MultipartEditor: View {
    @Binding var parts: [MultipartPart]

    @State private var draftName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(parts.indices, id: \.self) { index in
                    MultipartRow(part: $parts[index]) { remove(at: index) }
                    Divider()
                }
                blankRow
            }
        }
    }

    private var blankRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
            TextField("Field name", text: $draftName)
                .onChange(of: draftName) {
                    guard !draftName.isEmpty else { return }
                    parts.append(MultipartPart(name: draftName, content: .text("")))
                    draftName = ""
                }
            Spacer()
            Color.clear.frame(width: 20, height: 1)
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func remove(at index: Int) {
        DispatchQueue.main.async {
            guard parts.indices.contains(index) else { return }
            parts.remove(at: index)
        }
    }
}

private struct MultipartRow: View {
    @Binding var part: MultipartPart
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Include this part", isOn: $part.enabled)
                .labelsHidden()
                .help("Include this part")

            TextField("Field name", text: $part.name)
                .frame(maxWidth: 160)

            Picker("", selection: isFile) {
                Text("Text").tag(false)
                Text("File").tag(true)
            }
            .labelsHidden()
            .frame(width: 76)

            if case .file = part.content {
                FilePartField(path: filePath)
            } else {
                TextField("Value", text: textValue)
            }

            Button("Remove part", systemImage: "minus.circle", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(part.enabled ? 1 : 0.5)
    }

    private var isFile: Binding<Bool> {
        Binding(
            get: {
                guard case .file = part.content else { return false }
                return true
            },
            set: { part.content = $0 ? .file(path: "") : .text("") })
    }

    private var filePath: Binding<String> {
        Binding(
            get: {
                guard case .file(let path) = part.content else { return "" }
                return path
            },
            set: { part.content = .file(path: $0) })
    }

    private var textValue: Binding<String> {
        Binding(
            get: {
                guard case .text(let value) = part.content else { return "" }
                return value
            },
            set: { part.content = .text($0) })
    }
}

/// A path field with a Choose button. The path stays editable text so it can hold `{{variables}}`,
/// which the picker could never produce.
private struct FilePartField: View {
    @Binding var path: String

    var body: some View {
        HStack(spacing: 6) {
            TextField("Path to a file", text: $path)
            Button("Choose…") { path = FileChooser.choose() ?? path }
                .buttonStyle(.borderless)
        }
    }
}

/// One open panel, shared by the two places that attach a file.
///
/// The panel is the easy part; what matters is that both paths stay editable text afterwards, so a
/// `{{variable}}` can be typed where a picker could never produce one.
enum FileChooser {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// Query and variables side by side.
///
/// Variables are a JSON *string* rather than an object, matching how Postman stores them — see
/// `SendPlanBuilder`, which embeds it as a value when it parses and as a string when it does not.
private struct GraphQLEditor: View {
    @Binding var query: String
    @Binding var variables: String

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Query")
                TextEditor(text: $query)
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Variables (JSON)")
                TextEditor(text: $variables)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }
}

private struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }
}

private struct BinaryBodyEditor: View {
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField("Path to a file", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("Choose…") { path = FileChooser.choose() ?? path }
            }
            Caption(
                "Streamed from disk, so the file's size does not become the app's memory use.")
            Spacer()
        }
        .padding(16)
    }
}
