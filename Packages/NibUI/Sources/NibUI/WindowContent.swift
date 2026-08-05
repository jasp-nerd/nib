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
        RequestPane(session: model.session)
            .sheet(isPresented: Bindable(model).isPalettePresented) {
                CommandPalette(
                    model: model.collectionModel,
                    isPresented: Bindable(model).isPalettePresented
                )
                .withKeyboardHandling()
            }
    }
}

public struct ResponseContent: View {
    var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ResponsePane(session: model.session)
    }
}
