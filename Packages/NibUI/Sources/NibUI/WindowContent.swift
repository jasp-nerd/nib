import NibCore
import SwiftUI

/// Sidebar content, hosted from the window controller.
///
/// Takes `AppModel` rather than a `CollectionModel`, and reads through it inside `body`. That matters
/// for Phase 8: when tabs replace `session`, views that captured the old object at construction time
/// would silently keep showing it.
public struct SidebarContent: View {
    var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        SidebarView(model: model.collectionModel)
            .onChange(of: model.collectionModel.selectedRequestID) {
                model.loadSelectedRequest()
            }
            // The whole sidebar is a drop target, not a small area to aim at -- dropping an export is
            // the gesture the launch video shows.
            .importDropTarget(model.importCoordinator)
            // `isPresented` rather than `sheet(item:)`, because `report` is `private(set)` -- the
            // coordinator owns when a report exists, and the view only says when it has been read.
            .sheet(
                isPresented: .init(
                    get: { model.importCoordinator.report != nil },
                    set: { if !$0 { model.importCoordinator.dismissReport() } })
            ) {
                if let report = model.importCoordinator.report {
                    ImportReportSheet(report: report) {
                        model.importCoordinator.dismissReport()
                    }
                }
            }
            .alert(
                "Could not import",
                isPresented: .init(
                    get: { model.importCoordinator.failure != nil },
                    set: { if !$0 { model.importCoordinator.dismissReport() } })
            ) {
                Button("OK") { model.importCoordinator.dismissReport() }
            } message: {
                Text(model.importCoordinator.failure ?? "")
            }
    }
}

/// Request pane, plus the `⌘K` switcher sheet.
public struct RequestContent: View {
    var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.collectionModel.isOpen {
                EnvironmentBar(
                    model: model.collectionModel,
                    isEditorPresented: Bindable(model).isEnvironmentEditorPresented
                )
                Divider()
            }

            RequestPane(session: model.session)
                // Attached here rather than to the VStack: two `.sheet` modifiers on one view
                // fight over the same presentation slot, and the second one silently never shows.
                .sheet(isPresented: Bindable(model).isPalettePresented) {
                    CommandPalette(
                        model: model.collectionModel,
                        isPresented: Bindable(model).isPalettePresented
                    )
                    .withKeyboardHandling()
                }
        }
        // One property to watch instead of the whole environment array: switching environment and
        // typing a value both bump it, and both have to re-resolve the URL bar.
        .onChange(of: model.collectionModel.environmentsRevision) {
            model.refreshScope()
        }
        .sheet(
            isPresented: Bindable(model).isEnvironmentEditorPresented,
            // On dismiss rather than on the Done button, so Escape saves too.
            onDismiss: { Task { await model.collectionModel.commitEnvironments() } }
        ) {
            EnvironmentEditor(model: model.collectionModel) {
                model.isEnvironmentEditorPresented = false
            }
        }
    }
}
