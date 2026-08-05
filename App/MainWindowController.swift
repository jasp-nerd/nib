import AppKit
import NibUI
import Observation
import SwiftUI  // NSHostingController lives here, not in AppKit.

/// The main window: sidebar on the left, request over response on the right.
///
/// `NSSplitViewController` rather than SwiftUI's `HSplitView` for two concrete reasons.
/// `NSSplitViewItem(sidebarWithViewController:)` gives us the system sidebar material and
/// collapse behaviour for free; and the response body has to be a real `NSTextView` in a
/// real `NSViewController` further down this tree, because TextKit 2 rendering attributes
/// are unreliable inside `NSViewRepresentable`.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    /// Fired once, when the window has actually drawn. The launch number is reported from
    /// here rather than at the end of `applicationDidFinishLaunching`, which returns long
    /// before any pixels exist.
    var onFirstFrame: (() -> Void)?

    private var hasReportedFirstFrame = false
    private var hasSetInitialDivider = false

    /// The root store. Owned by the window controller for now; Phase 3 moves it up to the delegate
    /// once there is more than one window's worth of state.
    let model = AppModel()

    /// Held so `⌘F` can reach the text view's find bar. The alternative — walking the split view
    /// hierarchy looking for the right class — is the kind of thing that keeps compiling after
    /// someone rearranges the panes and then quietly does nothing.
    private(set) var responseController: ResponsePaneController?

    /// The object that vends the toolbar's items.
    ///
    /// Held **strongly**, and deliberately so, which is why it is not called `toolbarDelegate` —
    /// SwiftLint's `weak_delegate` rule matches on the name and it would be wrong here.
    /// `NSToolbar.delegate` is itself weak, and `NSWindow` only retains the toolbar, so nothing
    /// else in the graph keeps this alive: make it weak and the items stop being vended the moment
    /// the initialiser returns, leaving an empty toolbar and no error anywhere.
    private var mainToolbar: MainToolbar?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Nib"
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 720, height: 480)

        self.init(window: window)

        window.delegate = self

        let responseController = ResponsePaneController(model: model)
        self.responseController = responseController
        let root = Self.makeSplitViewController(model: model, response: responseController)
        root.onViewDidAppear = { [weak self] in
            self?.reportFirstFrameIfNeeded()
            self?.applyInitialDividerPositionIfNeeded()
        }
        window.contentViewController = root

        // Assigned after `contentViewController`, because the tracking separator needs the split
        // view that the root controller only has once its view is loaded.
        let mainToolbar = MainToolbar(splitView: root.splitView)
        self.mainToolbar = mainToolbar
        window.toolbar = mainToolbar.makeToolbar()

        observeCollection()

        // Order matters here, and getting it wrong is how the window ends up either the size of a
        // postage stamp or taller than the display:
        //
        //   1. Assigning contentViewController lets AppKit resize to fit. With intrinsic sizing
        //      switched off (see makeHost) the content suggests nothing, so the window collapses to
        //      minSize. Restate the size we actually want.
        //   2. Only then restore any frame the user themselves resized to.
        //   3. Clamp unconditionally. An autosaved frame from an older build can be nonsense, and a
        //      window taller than the screen silently hides the bottom pane -- indistinguishable,
        //      from the outside, from the app not working.
        window.setContentSize(Self.defaultContentSize)

        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        Self.clampToScreen(window)
    }

    private static let defaultContentSize = NSSize(width: 1100, height: 720)
    private static let frameAutosaveName = "NibMainWindow"

    // MARK: - Title

    /// Keep the titlebar saying which collection is open.
    ///
    /// A title/subtitle pair rather than a title alone: it is the standard macOS way to say "this
    /// window, from that place", it survives the toolbar collapsing on a narrow window, and it puts
    /// the folder path in the window's proxy-icon-shaped slot, which is where someone looking for
    /// "where did this actually come from" looks first.
    ///
    /// `withObservationTracking` rather than a Combine subscription or a poll — same pattern as
    /// `ResponsePaneController`, and for the same reason: `onChange` fires once, before the change
    /// lands, so the callback has to hop to the next main-actor turn and re-arm. Not re-arming
    /// gives you a title that updates exactly once.
    private func observeCollection() {
        withObservationTracking {
            _ = model.collectionModel.rootURL
            _ = model.collectionModel.collection?.name
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateTitle()
                observeCollection()
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let window else { return }

        guard let root = model.collectionModel.rootURL else {
            window.title = "Nib"
            window.subtitle = ""
            return
        }

        window.title = model.collectionModel.collection?.name ?? root.lastPathComponent
        // Abbreviated, so a collection under the home directory reads `~/Code/api` rather than
        // eating the whole titlebar with `/Users/…`.
        window.subtitle = (root.path as NSString).abbreviatingWithTildeInPath
    }

    /// Put the request/response divider at roughly 40% on first run.
    ///
    /// `preferredThicknessFraction` is ignored for a non-sidebar item in a nested split, so the
    /// divider has to be positioned explicitly — and only once layout exists, hence `viewDidAppear`
    /// rather than `init`. After the first run the split view's own `autosaveName` restores whatever
    /// the user dragged it to, so this must not fight that.
    private func applyInitialDividerPositionIfNeeded() {
        guard !hasSetInitialDivider else { return }
        hasSetInitialDivider = true

        // Respect a restored position: if the user has ever dragged this divider, leave it alone.
        guard
            UserDefaults.standard.object(forKey: "NSSplitView Subview Frames NibDetailSplit") == nil
        else { return }

        guard let root = window?.contentViewController as? NSSplitViewController,
            let detail = root.splitViewItems.last?.viewController as? NSSplitViewController
        else { return }

        let height = detail.splitView.bounds.height
        guard height > 0 else { return }
        detail.splitView.setPosition(height * 0.4, ofDividerAt: 0)
    }

    private static func clampToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }

        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)

        // Pull it back inside if the clamped size left it hanging off an edge.
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)

        guard frame != window.frame else { return }
        window.setFrame(frame, display: false)
    }

    /// Host a SwiftUI view **without** letting it size the window.
    ///
    /// `NSHostingController` defaults to propagating its content's intrinsic size upward via
    /// `preferredContentSize`. A `TextEditor` or `ScrollView` asks for unbounded height, so the
    /// default inflated the window to 720x1621 — taller than the screen — which pushed the response
    /// pane off the bottom of the display entirely. The request appeared to do nothing; in fact it
    /// had succeeded and was being drawn where nobody could see it.
    ///
    /// Clearing `sizingOptions` makes the container drive the size, which is what we want: the split
    /// view decides, the content fits.
    private static func makeHost<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        return host
    }

    private static func makeSplitViewController(
        model: AppModel,
        response responseController: ResponsePaneController
    ) -> RootSplitViewController {
        let split = RootSplitViewController()

        let sidebar = NSSplitViewItem(
            sidebarWithViewController: makeHost(SidebarContent(model: model))
        )
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 420
        sidebar.canCollapse = true
        // The sidebar runs the full height of the window, up behind the titlebar, which is what
        // makes it read as a floating glass pane rather than a panel bolted below the toolbar.
        // This is the default on macOS 26, but it is stated because the window also sets
        // `fullSizeContentView`, and the two together are what produce the effect — leaving it
        // implicit means a later change to the style mask silently undoes it.
        sidebar.allowsFullHeightLayout = true
        // No hairline under the titlebar on the sidebar side. The scroll edge effect is what
        // separates the toolbar from the list now, and a line as well as a fade is one separator
        // too many.
        sidebar.titlebarSeparatorStyle = .none

        // The request/response pair is its own vertical split so the View menu's
        // "Toggle Split Orientation" can flip it without disturbing the sidebar.
        let detail = NSSplitViewController()
        detail.splitView.isVertical = false
        detail.splitView.dividerStyle = .thin
        detail.splitView.autosaveName = "NibDetailSplit"

        let request = NSSplitViewItem(
            viewController: makeHost(RequestContent(model: model))
        )
        request.minimumThickness = 160
        // Higher holding priority than the response, so dragging the window taller grows the
        // response rather than the editor. Reading the response is why the window is open.
        //
        // Note: `preferredThicknessFraction` was tried here and measurably does nothing for a
        // non-sidebar item in a nested split. The initial 40/60 split is set explicitly in
        // `applyInitialDividerPositionIfNeeded`.
        request.holdingPriority = .defaultLow + 1

        // Not an `NSHostingController`. The response body is a real `NSTextView` on TextKit 2,
        // and the reason it is not wrapped in an `NSViewRepresentable` is written up on
        // `ResponseBodyView`.
        let response = NSSplitViewItem(viewController: responseController)
        response.minimumThickness = 160
        response.holdingPriority = .defaultLow

        detail.addSplitViewItem(request)
        detail.addSplitViewItem(response)

        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: detail))
        split.splitView.autosaveName = "NibMainSplit"

        return split
    }

    // MARK: - NSWindowDelegate

    /// Secondary trigger. `viewDidAppear` on the root controller is the primary one; this only
    /// matters if the window somehow becomes key first. Whichever fires first wins, and the
    /// latch makes the double-reporting harmless.
    func windowDidBecomeKey(_ notification: Notification) {
        reportFirstFrameIfNeeded()
    }

    private func reportFirstFrameIfNeeded() {
        guard !hasReportedFirstFrame else { return }
        hasReportedFirstFrame = true
        onFirstFrame?()
    }
}
