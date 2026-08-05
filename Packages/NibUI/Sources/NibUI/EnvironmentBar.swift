import NibCore
import SwiftUI

/// The environment picker, sitting directly above the URL field.
///
/// Not in an `NSToolbar`, which is where the plan put it. The toolbar would mean an
/// `NSHostingView` item in the AppKit shell and a second path for state to travel down; putting
/// it here costs nothing and keeps it in the same glance as the URL it is about to rewrite —
/// which is the point of the control.
struct EnvironmentBar: View {
    var model: CollectionModel
    @Binding var isEditorPresented: Bool

    var body: some View {
        HStack(spacing: 8) {
            EnvironmentMenu(model: model, isEditorPresented: $isEditorPresented)
            Spacer()
            EnvironmentStatus(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct EnvironmentMenu: View {
    var model: CollectionModel
    @Binding var isEditorPresented: Bool

    var body: some View {
        Menu {
            // "No environment" is a first-class choice, not an empty state: it is how you check
            // what a request does against collection defaults alone.
            Button {
                model.setActiveEnvironment(nil)
            } label: {
                Label("No environment", systemImage: tick(for: nil))
            }

            if !model.environments.isEmpty {
                Divider()
                ForEach(model.environments) { environment in
                    Button {
                        model.setActiveEnvironment(environment.id)
                    } label: {
                        Label(environment.name, systemImage: tick(for: environment.id))
                    }
                }
            }

            Divider()
            Button("Manage Environments…") { isEditorPresented = true }
        } label: {
            Label(
                model.activeEnvironment?.name ?? "No environment",
                systemImage: "globe"
            )
            .foregroundStyle(model.activeEnvironment == nil ? .secondary : .primary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which environment supplies {{variables}}")
    }

    /// SF Symbols has no "nothing" glyph, and an empty string draws a gap that makes the menu
    /// items fail to line up. `circle` at clear opacity would need a custom label; this is the
    /// cheap version that keeps the titles aligned.
    private func tick(for id: NodeID?) -> String {
        model.activeEnvironmentID == id ? "checkmark" : "square.dashed"
    }
}

/// Variable count, or the reason the Keychain is unavailable.
///
/// The failure gets the space because of what it implies: while it is showing, Nib is refusing to
/// write secrets at all, and silently not saving someone's token is exactly the kind of thing
/// that has to be said out loud.
private struct EnvironmentStatus: View {
    var model: CollectionModel

    var body: some View {
        if let failure = model.secretsFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        } else if let environment = model.activeEnvironment {
            Text(Self.summary(of: environment))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static func summary(of environment: NibCore.Environment) -> String {
        let enabled = environment.variables.filter(\.enabled)
        let missing = enabled.filter { $0.secret && ($0.value ?? "").isEmpty }.count

        let variables = "\(enabled.count) variable\(enabled.count == 1 ? "" : "s")"
        guard missing > 0 else { return variables }
        return "\(variables) · \(missing) secret\(missing == 1 ? "" : "s") not set"
    }
}
