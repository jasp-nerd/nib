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
