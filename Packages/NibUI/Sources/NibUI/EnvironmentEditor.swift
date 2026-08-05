import NibCore
import SwiftUI

/// The environment editor sheet.
///
/// Edits go straight into the model as you type — so `{{baseUrl}}` in the URL bar behind the
/// sheet resolves live — and reach the disk and the Keychain exactly once, when the sheet closes.
/// The commit is wired to the sheet's `onDismiss` rather than to the Done button, so pressing
/// Escape saves too. Losing ten minutes of typed tokens to the wrong key is not a tradeoff worth
/// making for the purity of a Cancel button.
public struct EnvironmentEditor: View {
    var model: CollectionModel
    var onClose: () -> Void

    @State private var selectedID: NodeID?

    public init(model: CollectionModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EnvironmentListColumn(model: model, selectedID: $selectedID)
                Divider()
                detail
            }
            Divider()
            EditorFooter(onClose: onClose)
        }
        .frame(width: 720, height: 420)
        // Start on whatever the picker is showing, so opening the editor lands on the environment
        // the user was just looking at rather than the alphabetically first one.
        .onAppear { selectedID = model.activeEnvironmentID ?? model.environments.first?.id }
        .onChange(of: model.environments.map(\.id)) {
            if let selectedID, model.environments.contains(where: { $0.id == selectedID }) {
                return
            }
            selectedID = model.environments.first?.id
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedID, model.environments.contains(where: { $0.id == selectedID }) {
            EnvironmentDetail(environment: binding(for: selectedID))
        } else {
            NoEnvironmentSelected(model: model)
        }
    }

    /// Looked up by id on every access, in both directions.
    ///
    /// Capturing the array index instead would be one delete away from writing an edit into the
    /// wrong environment — the same stale-index shape that already bit the header table.
    private func binding(for id: NodeID) -> Binding<NibCore.Environment> {
        Binding(
            get: {
                model.environments.first { $0.id == id } ?? NibCore.Environment(id: id, name: "")
            },
            set: { model.stage($0) }
        )
    }
}

// MARK: - Left column

private struct EnvironmentListColumn: View {
    var model: CollectionModel
    @Binding var selectedID: NodeID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedID) {
                ForEach(model.environments) { environment in
                    Label(environment.name, systemImage: "globe")
                        .lineLimit(1)
                        .tag(environment.id)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 4) {
                Button("New environment", systemImage: "plus") {
                    selectedID = model.stageAddEnvironment()
                }
                .labelStyle(.iconOnly)
                .help("New environment")

                Button("Delete environment", systemImage: "minus") {
                    guard let selectedID else { return }
                    model.stageDeleteEnvironment(selectedID)
                }
                .labelStyle(.iconOnly)
                .disabled(selectedID == nil)
                .help("Delete environment")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 190)
    }
}

private struct NoEnvironmentSelected: View {
    var model: CollectionModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No environments yet")
                .font(.headline)
            Text("An environment is a named set of {{variables}} — one per server you talk to.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("New Environment") { model.stageAddEnvironment() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Right column

private struct EnvironmentDetail: View {
    @Binding var environment: NibCore.Environment

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("Staging", text: $environment.name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()
            VariableHeaderRow()
            Divider()
            VariableTable(variables: $environment.variables)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct VariableHeaderRow: View {
    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 1)
            Text("Key").frame(maxWidth: .infinity, alignment: .leading)
            Text("Value").frame(maxWidth: .infinity, alignment: .leading)
            Text("Secret").frame(width: 52, alignment: .center)
            Color.clear.frame(width: 20, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

private struct VariableTable: View {
    @Binding var variables: [EnvironmentVariable]

    /// Real `@State`, for the reason spelled out on `HeaderTable.draftName`: a binding whose getter
    /// always returns "" drives the field back to empty after every committed keystroke.
    @State private var draftKey = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(variables.indices, id: \.self) { index in
                    VariableRow(variable: $variables[index]) { remove(at: index) }
                    Divider()
                }
                blankRow
            }
        }
    }

    /// Deferred for the same reason as the header table's: mutating the array while a later row's
    /// focused field still holds a binding to its old index commits an edit through a stale index.
    private func remove(at index: Int) {
        DispatchQueue.main.async {
            guard variables.indices.contains(index) else { return }
            variables.remove(at: index)
        }
    }

    private var blankRow: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
            TextField("Key", text: $draftKey)
                .onChange(of: draftKey) {
                    guard !draftKey.isEmpty else { return }
                    variables.append(EnvironmentVariable(key: draftKey, value: ""))
                    draftKey = ""
                }
            Spacer()
            Color.clear.frame(width: 72, height: 1)
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct VariableRow: View {
    @Binding var variable: EnvironmentVariable
    var onRemove: () -> Void

    /// `value` is optional on the model because `null` on disk is what marks a secret whose value
    /// lives in the Keychain. A text field cannot bind to that, so empty maps to nil on the way
    /// back — which keeps "typed nothing" and "not stored" the same state, as they should be.
    private var text: Binding<String> {
        Binding(
            get: { variable.value ?? "" },
            set: { variable.value = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Use this variable", isOn: $variable.enabled)
                .labelsHidden()
                .help("Use this variable")

            TextField("Key", text: $variable.key)

            if variable.secret {
                SecureField("Kept in your Keychain", text: text)
            } else {
                TextField("Value", text: text)
            }

            Toggle("Secret", isOn: $variable.secret)
                .labelsHidden()
                .frame(width: 52, alignment: .center)
                .help("Keep this value in the Keychain instead of the file")

            Button("Remove variable", systemImage: "minus.circle", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
        }
        .font(.system(.body, design: .monospaced))
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(variable.enabled ? 1 : 0.5)
    }
}

// MARK: - Footer

private struct EditorFooter: View {
    var onClose: () -> Void

    var body: some View {
        HStack {
            Label(
                "Secret values go to your Keychain. The file records the key with a null value.",
                systemImage: "lock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
