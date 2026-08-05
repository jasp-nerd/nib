import AppKit

/// The window's toolbar.
///
/// The window previously had none — `toolbarStyle` was set, `styleMask` included
/// `.fullSizeContentView`, and then nothing was ever assigned to `window.toolbar`. That is a real
/// gap on macOS 26 rather than a cosmetic one: the toolbar is where the system puts Liquid Glass,
/// and a titlebar with nothing in it is the one part of a window that cannot adopt the new design
/// by being rebuilt, because there is nothing there to adopt it.
///
/// Everything here is deliberately thin. No item owns state, no item holds a reference to the
/// model, and every action is `target: nil` so it travels the responder chain to the same
/// `AppDelegate` method the menu item calls. That means `validateMenuItem` keeps being the single
/// place enablement is decided — a toolbar with its own idea of when Send is available is a second
/// source of truth, and the two drift.
final class MainToolbar: NSObject, NSToolbarDelegate {

    /// Held weakly: the toolbar is retained by the window, the window by the controller, and the
    /// split view is the controller's content. A strong reference here closes that loop.
    private weak var splitView: NSSplitView?

    init(splitView: NSSplitView) {
        self.splitView = splitView
        super.init()
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "NibMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // Customisable, because which of these three someone reaches for depends entirely on
        // whether they live in the sidebar or in ⌘K, and that is not a thing to guess at.
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        return toolbar
    }

    // MARK: - NSToolbarDelegate

    private static let goToRequest = NSToolbarItem.Identifier("app.nib.goToRequest")
    private static let newRequest = NSToolbarItem.Identifier("app.nib.newRequest")
    private static let importPostman = NSToolbarItem.Identifier("app.nib.importPostman")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            // Pins the toolbar's own divider to the split view's, so the sidebar's glass and the
            // toolbar's glass share one edge as the divider is dragged. Without it the two
            // separate as soon as the sidebar is resized, which is the single most visible way an
            // AppKit window looks like it was built for an older OS.
            .sidebarTrackingSeparator,
            .flexibleSpace,
            Self.goToRequest,
            // A fixed space, not a flexible one: `goToRequest` and the two creation actions are
            // different kinds of thing, and macOS 26 groups toolbar items onto shared glass by
            // proximity. The gap is what tells the system these are two groups.
            .space,
            Self.newRequest,
            Self.importPostman,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .sidebarTrackingSeparator:
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(
                identifier: identifier, splitView: splitView, dividerIndex: 0)

        case Self.goToRequest:
            return item(
                identifier,
                label: "Go to Request",
                symbol: "magnifyingglass",
                tooltip: "Go to Request… (⌘K)",
                action: #selector(AppDelegate.showPalette(_:)))

        case Self.newRequest:
            return item(
                identifier,
                label: "New Request",
                symbol: "plus",
                tooltip: "New Request (⌘N)",
                action: #selector(AppDelegate.newRequest(_:)))

        case Self.importPostman:
            return item(
                identifier,
                label: "Import",
                symbol: "square.and.arrow.down",
                tooltip: "Import from Postman… (⌘I)",
                action: #selector(AppDelegate.importFromPostman(_:)))

        default:
            return nil
        }
    }

    private func item(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        tooltip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        // Shown in the customisation palette and the overflow menu, where "New Request" without a
        // window's worth of context around it is the only thing to read.
        item.paletteLabel = label
        item.toolTip = tooltip
        item.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: label)
        item.action = action
        item.target = nil
        // This is what puts the item *on* Liquid Glass. An unbordered toolbar item on macOS 26 is
        // the "decoration, not a control" case — it draws bare, with no glass pill behind it — and
        // these three are all controls.
        item.isBordered = true
        return item
    }
}
