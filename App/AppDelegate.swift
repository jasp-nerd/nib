import AppKit
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
    private var mainWindowController: MainWindowController?

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
        runSelfTestIfRequested()
    }

    /// Diagnostic hook: send one request through the real app and report what happened.
    ///
    ///     NIB_SELFTEST=https://example.com dist/Nib.app/Contents/MacOS/Nib
    ///
    /// This exists because a GUI bug and an engine bug look identical from the outside — "I clicked
    /// send and nothing happened" is true whether the request failed, or succeeded and was rendered
    /// somewhere invisible. Exercising the app's own model, with the app's own Info.plist and ATS
    /// policy, separates the two. The unit tests cannot: they run in a test bundle that has neither.
    private func runSelfTestIfRequested() {
        guard let target = ProcessInfo.processInfo.environment["NIB_SELFTEST"],
            let controller = mainWindowController
        else { return }

        let session = controller.model.session
        session.spec.url = target

        func report(_ line: String) {
            FileHandle.standardError.write(Data("[selftest] \(line)\n".utf8))
        }

        report("url: \(target)")
        report("canSend: \(session.canSend)")

        // Pane geometry, because "nothing happened" is also what a collapsed response pane looks
        // like, and the autosaved divider position survives across builds.
        if let window = controller.window {
            report("window: \(Int(window.frame.width))x\(Int(window.frame.height))")
            if let split = window.contentViewController as? NSSplitViewController {
                for (index, item) in split.splitViewItems.enumerated() {
                    let size = item.viewController.view.frame
                    report(
                        "  pane \(index): \(Int(size.width))x\(Int(size.height)) "
                            + "collapsed=\(item.isCollapsed)")
                    if let nested = item.viewController as? NSSplitViewController {
                        for (subIndex, subItem) in nested.splitViewItems.enumerated() {
                            let subSize = subItem.viewController.view.frame
                            report(
                                "    subpane \(subIndex): \(Int(subSize.width))x"
                                    + "\(Int(subSize.height)) collapsed=\(subItem.isCollapsed)")
                        }
                    }
                }
            }
        }

        session.send()

        Task {
            await session.inFlight?.value
            report("state: \(session.state)")
            report("notes: \(session.notes)")
            report("unresolved: \(session.unresolved.map(\.name))")
            if let response = session.response {
                report("RESPONSE \(response.status) \(response.statusText)")
                report("  duration: \(response.durationText)  size: \(response.sizeText)")
                report("  body[0..120]: \(response.bodyText.prefix(120))")
            } else {
                report("RESPONSE: none")
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    private var model: AppModel? { mainWindowController?.model }

    @objc func sendRequest(_ sender: Any?) {
        model?.sendCurrentRequest()
    }

    @objc func cancelRequest(_ sender: Any?) {
        model?.cancelCurrentRequest()
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
