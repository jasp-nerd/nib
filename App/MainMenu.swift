import AppKit

/// The menu bar, built in code.
///
/// No MainMenu.xib. A nib here would be one more binary blob in the bundle, unreviewable in
/// a diff, and it would need loading during launch. Building menus in code costs a few
/// microseconds and every entry is greppable.
///
/// Every keyboard shortcut in the app appears here too, so it is discoverable and shows up
/// in Help search. If a shortcut exists only as a local key handler, that is a bug.
///
/// Disabled placeholders are deliberate. The whole shortcut map is laid out up front so it
/// stays coherent, rather than each phase grabbing whichever key happens to be free.
enum MainMenu {
    /// `target` receives the app-specific actions (send, cancel, cURL interchange). Passing it in
    /// rather than relying on the responder chain keeps the wiring greppable: every enabled item
    /// below names the selector it calls.
    static func install(into app: NSApplication, target: AnyObject) {
        let root = NSMenu()
        root.addItem(appMenuItem())
        root.addItem(fileMenuItem(target: target))
        root.addItem(editMenuItem(target: target))
        root.addItem(viewMenuItem(target: target))
        root.addItem(windowMenuItem(app: app))
        app.mainMenu = root
    }

    // MARK: - Menus

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        add(menu, "About Nib", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        add(menu, "Settings…", nil, key: ",", enabled: false)  // Phase 8
        menu.addItem(.separator())
        add(menu, "Hide Nib", #selector(NSApplication.hide(_:)), key: "h")
        add(menu, "Quit Nib", #selector(NSApplication.terminate(_:)), key: "q")
        return wrap("Nib", menu)
    }

    private static func fileMenuItem(target: AnyObject) -> NSMenuItem {
        let menu = NSMenu(title: "File")
        add(menu, "New Tab", #selector(AppDelegate.newTab(_:)), key: "t", target: target)
        add(menu, "New Request", #selector(AppDelegate.newRequest(_:)), key: "n", target: target)
        add(
            menu, "New Folder", #selector(AppDelegate.newFolder(_:)), key: "N",
            modifiers: [.command, .shift], target: target)
        menu.addItem(.separator())
        add(
            menu, "Open Collection Folder…", #selector(AppDelegate.openCollection(_:)), key: "o",
            target: target)
        add(
            menu, "Close Collection", #selector(AppDelegate.closeCollection(_:)), key: "w",
            modifiers: [.command, .shift, .option], target: target)
        menu.addItem(.separator())
        add(menu, "Save", #selector(AppDelegate.saveRequest(_:)), key: "s", target: target)
        add(
            menu, "Go to Request…", #selector(AppDelegate.showPalette(_:)), key: "k",
            target: target)
        add(
            menu, "Environments…", #selector(AppDelegate.showEnvironments(_:)), key: "e",
            target: target)
        menu.addItem(.separator())
        add(
            menu, "Import from Postman…", #selector(AppDelegate.importFromPostman(_:)), key: "i",
            modifiers: [.command, .shift], target: target)
        menu.addItem(.separator())
        add(
            menu, "Send Request", #selector(AppDelegate.sendRequest(_:)), key: "\r",
            target: target)
        add(
            menu, "Cancel Request", #selector(AppDelegate.cancelRequest(_:)), key: ".",
            target: target)
        menu.addItem(.separator())
        add(
            menu, "Copy as cURL", #selector(AppDelegate.copyAsCurl(_:)), key: "C",
            modifiers: [.command, .shift], target: target)
        add(
            menu, "Copy as cURL (Redacted)", #selector(AppDelegate.copyAsCurlRedacted(_:)),
            key: "C", modifiers: [.command, .shift, .option], target: target)
        menu.addItem(.separator())
        add(menu, "Close Tab", #selector(AppDelegate.closeTab(_:)), key: "w", target: target)
        add(
            menu, "Close Window", #selector(NSWindow.performClose(_:)), key: "W",
            modifiers: [.command, .shift])
        return wrap("File", menu)
    }

    private static func editMenuItem(target: AnyObject) -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        // Undo/redo are resolved dynamically by the responder chain, so they are referenced
        // by name rather than by a typed selector.
        add(menu, "Undo", Selector(("undo:")), key: "z")
        add(menu, "Redo", Selector(("redo:")), key: "Z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(NSText.cut(_:)), key: "x")
        add(menu, "Copy", #selector(NSText.copy(_:)), key: "c")
        add(menu, "Paste", #selector(NSText.paste(_:)), key: "v")
        add(
            menu, "Paste cURL as Request", #selector(AppDelegate.pasteCurlAsRequest(_:)),
            key: "v", modifiers: [.command, .option], target: target)
        add(menu, "Select All", #selector(NSText.selectAll(_:)), key: "a")
        menu.addItem(.separator())
        add(
            menu, "Find in Response", #selector(AppDelegate.findInResponse(_:)), key: "f",
            target: target)
        return wrap("Edit", menu)
    }

    private static func viewMenuItem(target: AnyObject) -> NSMenuItem {
        let menu = NSMenu(title: "View")
        // Cmd-1 through Cmd-5 select a tab by position; beyond five, use the switcher.
        for index in 1...5 {
            add(
                menu, "Tab \(index)", #selector(AppDelegate.selectTabByNumber(_:)),
                key: "\(index)", target: target, tag: index - 1)
        }
        add(
            menu, "Previous Tab", #selector(AppDelegate.previousTab(_:)), key: "[",
            modifiers: [.command, .shift], target: target)
        add(
            menu, "Next Tab", #selector(AppDelegate.nextTab(_:)), key: "]",
            modifiers: [.command, .shift], target: target)
        menu.addItem(.separator())
        add(
            menu, "Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)),
            key: "s", modifiers: [.command, .control]
        )
        add(
            menu, "Focus URL Field", #selector(AppDelegate.focusURLField(_:)), key: "l",
            target: target)
        menu.addItem(.separator())
        add(
            menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)),
            key: "f", modifiers: [.command, .control]
        )
        return wrap("View", menu)
    }

    private static func windowMenuItem(app: NSApplication) -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        app.windowsMenu = menu
        return wrap("Window", menu)
    }

    // MARK: - Helpers

    private static func wrap(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil,
        enabled: Bool = true,
        tag: Int = 0
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.tag = tag
        if !key.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        // An explicit target bypasses the responder chain. Without it these actions would only fire
        // when the right view happened to be first responder, which for a global "send" is wrong.
        item.target = target
        // An item with no action is disabled by the responder chain anyway; setting it
        // explicitly keeps the not-yet-implemented entries visibly greyed rather than
        // appearing live and doing nothing.
        item.isEnabled = enabled
        menu.addItem(item)
    }
}
