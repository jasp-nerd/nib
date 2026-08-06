import AppKit
import NibCore
import NibUI

/// Application lifecycle.
///
/// INVARIANT: `applicationDidFinishLaunching` does exactly three things -- build the menu,
/// create the window, show it. Nothing else. Everything with a cost (reopening the last
/// collection, warming the HTTP engine, reading response history, checking for an update)
/// happens in `deferredStartup()` *after* the first frame.
///
/// This is not premature optimisation; it is the whole reason the app can claim a launch
/// number. It is also the single easiest invariant to break by accident, because adding
/// "just one quick thing" here is always the path of least resistance.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Not `private`: `SelfTest.swift` extends this type and needs the window.
    var mainWindowController: MainWindowController?

    /// A folder Finder handed us before the window existed. See `application(_:open:)`.
    private var pendingOpen: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install(into: NSApplication.shared, target: self)

        let controller = MainWindowController()
        mainWindowController = controller

        // Assign BEFORE showWindow. `windowDidBecomeKey` can fire synchronously inside
        // showWindow, and the controller latches `hasReportedFirstFrame` on the first
        // notification either way -- so assigning afterwards means the callback is still nil
        // when it fires and the launch number is never reported at all.
        controller.onFirstFrame = { LaunchMetrics.endLaunch() }

        controller.showWindow(nil)

        // Hop to the next runloop pass so this cannot land inside the first frame.
        //
        // `perform(inModes:)` hands us a nonisolated closure, but it always fires on the main
        // thread's runloop -- so the isolation is real even though the signature cannot express
        // it, and `assumeIsolated` is the sound way to say so. A `Task { @MainActor in }` would
        // also compile, but it makes no guarantee about running after the first frame, which is
        // the entire point of this hop.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.deferredStartup()
            }
        }
    }

    /// Everything that is allowed to cost time. Runs after the window is visible.
    private func deferredStartup() {
        // Phase 3+ will reopen the last collection folder here; Phase 6 warms the response
        // text view.
        if let url = pendingOpen, let model {
            pendingOpen = nil
            open(url, in: model)
        }

        runSelfTestIfRequested()
        runCollectionSelfTestIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Open a collection folder handed to us by Finder, `open`, or a drop on the Dock icon.
    ///
    /// Without this, AppKit falls back to its own document machinery and puts up "Nib cannot open
    /// files in the “folder” format" — with Nib's icon on it, so it reads as the app being broken.
    /// That is a bad way to greet someone who just did the most natural thing available to them:
    /// the whole premise is that a collection *is* a folder, so of course people double-click one.
    ///
    /// Importable files are routed to the importer rather than refused, so dropping a Postman
    /// export on the Dock icon does what dropping it on the window does.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        // On a cold launch AppKit delivers this *before* `applicationDidFinishLaunching`, so there
        // is no window and no model yet. Hold the URL and open it once there is one; dropping it
        // here is why double-clicking a collection folder opened an empty window.
        guard let model else {
            pendingOpen = url
            return
        }
        open(url, in: model)
    }

    private func open(_ url: URL, in model: AppModel) {
        Task {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: url.path, isDirectory: &isDirectory)
            guard exists else { return }

            // A folder could be either a collection or an unzipped Postman export. Only one of
            // them has a collection.json in it, so there is no need to guess.
            let isCollection = FileManager.default.fileExists(
                atPath: url.appendingPathComponent("collection.json").path)

            if isDirectory.boolValue && (isCollection || !model.collectionModel.isOpen) {
                await model.collectionModel.open(url)
            } else {
                await model.importCoordinator.importFiles([url])
            }
        }
    }

    // MARK: - Menu actions

    var model: AppModel? { mainWindowController?.model }

    @objc func sendRequest(_ sender: Any?) {
        model?.sendCurrentRequest()
    }

    @objc func cancelRequest(_ sender: Any?) {
        model?.cancelCurrentRequest()
    }

    @objc func openCollection(_ sender: Any?) {
        guard let model else { return }
        Task { await model.collectionModel.promptToOpen() }
    }

    @objc func closeCollection(_ sender: Any?) {
        model?.collectionModel.close()
    }

    @objc func saveRequest(_ sender: Any?) {
        guard let model else { return }
        Task { await model.saveSelectedRequest() }
    }

    @objc func importFromPostman(_ sender: Any?) {
        guard let model else { return }
        Task { await model.importCoordinator.promptToImport() }
    }

    @objc func showPalette(_ sender: Any?) {
        model?.isPalettePresented = true
    }

    @objc func showEnvironments(_ sender: Any?) {
        model?.isEnvironmentEditorPresented = true
    }

    // MARK: Tabs

    @objc func newTab(_ sender: Any?) {
        model?.newTab()
    }

    @objc func closeTab(_ sender: Any?) {
        guard let model else { return }
        // The last tab closes the window rather than leaving an empty one, which is what every
        // tabbed app does and what Cmd-W is expected to eventually do.
        guard model.canCloseTab else {
            mainWindowController?.window?.performClose(nil)
            return
        }
        model.closeTab(model.activeTabID)
    }

    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        model?.selectTab(at: item.tag)
    }

    @objc func previousTab(_ sender: Any?) {
        model?.selectNextTab(by: -1)
    }

    @objc func nextTab(_ sender: Any?) {
        model?.selectNextTab(by: 1)
    }

    // MARK: Collection

    @objc func newRequest(_ sender: Any?) {
        guard let model else { return }
        Task { await model.collectionModel.addRequest() }
    }

    @objc func newFolder(_ sender: Any?) {
        guard let model else { return }
        Task { await model.collectionModel.addFolder() }
    }

    @objc func focusURLField(_ sender: Any?) {
        model?.focusURLRequests += 1
    }

    @objc func findInResponse(_ sender: Any?) {
        mainWindowController?.responseController?.showFindBar()
    }

    @objc func copyAsCurl(_ sender: Any?) {
        report(model?.copyAsCurl(redacted: false))
    }

    @objc func copyAsCurlRedacted(_ sender: Any?) {
        report(model?.copyAsCurl(redacted: true))
    }

    @objc func pasteCurlAsRequest(_ sender: Any?) {
        report(model?.pasteCurlFromClipboard())
    }

    /// Menu items with an explicit target still get validated through here, so a disabled item is
    /// genuinely unavailable rather than silently doing nothing when clicked.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return false }

        switch item.action {
        case #selector(sendRequest(_:)):
            return model.session.canSend
        case #selector(cancelRequest(_:)):
            return model.session.state.isSending
        case #selector(pasteCurlAsRequest(_:)):
            return model.clipboardHoldsCurlCommand
        case #selector(saveRequest(_:)):
            return model.canSaveSelectedRequest
        case #selector(closeCollection(_:)), #selector(showPalette(_:)),
            #selector(importFromPostman(_:)), #selector(showEnvironments(_:)),
            #selector(newRequest(_:)), #selector(newFolder(_:)):
            return model.collectionModel.isOpen
        case #selector(selectTabByNumber(_:)):
            return (item.tag) < model.tabs.count
        case #selector(previousTab(_:)), #selector(nextTab(_:)):
            return model.tabs.count > 1
        case #selector(findInResponse(_:)):
            return mainWindowController?.responseController?.canFind == true
        case #selector(copyAsCurl(_:)), #selector(copyAsCurlRedacted(_:)):
            return !model.session.spec.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    /// Surface a failed menu action as an alert.
    ///
    /// These are user mistakes rather than programming errors — pasting something that is not a curl
    /// command, or copying before typing a URL — so they get a plain sheet, not a log line nobody
    /// reads.
    private func report(_ message: String?) {
        guard let message else { return }

        let alert = NSAlert()
        alert.messageText = "Nothing to do"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if let window = mainWindowController?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
