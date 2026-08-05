import AppKit

/// The window's root split view: sidebar | (request over response).
///
/// It exists as its own type mainly to get a trustworthy first-frame signal.
/// `viewDidAppear()` fires when the hierarchy is actually on screen, which is the honest
/// definition of "launched". The obvious alternatives do not work:
/// `windowDidExpose` is only sent for non-retained backing stores and so is effectively never
/// called for a buffered window, and `windowDidBecomeKey` never fires at all if the app was
/// started without being activated -- which is exactly how a measurement script starts it.
final class RootSplitViewController: NSSplitViewController {
    var onViewDidAppear: (() -> Void)?

    private var hasAppeared = false

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasAppeared else { return }
        hasAppeared = true
        onViewDidAppear?()
    }
}
