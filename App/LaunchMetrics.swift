import Foundation
import os

/// Launch-time instrumentation.
///
/// Phase 0 exists to establish the launch floor *before* there is any UI, so we know how much
/// of the 400 ms budget SwiftUI, Observation and our own code each consume. Measuring after the
/// app is built tells you the number; measuring from the first commit tells you which change
/// caused it.
///
/// Scope: this measures from `main()` entry to first frame. Everything before `main()` is
/// dyld's work and is measured separately with `DYLD_PRINT_STATISTICS=1` -- see
/// `Tools/measure-launch.sh`, which reports both.
///
/// Two outputs: an `os_signpost` interval for Instruments' App Launch template, and a stderr
/// line when `NIB_LAUNCH_TRACE=1` is set.
enum LaunchMetrics {
    private static let signposter = OSSignposter(
        logHandle: .init(subsystem: "app.nib.Nib", category: "launch"))

    /// Deliberately a stored var assigned in `beginLaunch()`, NOT a `static let = .now`.
    ///
    /// Swift initializes static lets lazily, on first access. A `static let processStart =
    /// ContinuousClock.now` therefore records the moment something first *reads* it -- which is
    /// inside `endLaunch()` -- and every launch measures as 0.0 ms. That is not a hypothetical;
    /// it is what this file did before this comment existed.
    private static var startInstant: ContinuousClock.Instant?

    private static var intervalState: OSSignpostIntervalState?
    private static var hasReported = false

    /// Called as the very first statement in `main.swift`.
    static func beginLaunch() {
        startInstant = ContinuousClock.now
        intervalState = signposter.beginInterval("launch", id: signposter.makeSignpostID())
    }

    /// Called once, when the window hierarchy is actually on screen.
    ///
    /// Reported from `RootSplitViewController.viewDidAppear`, not from the end of
    /// `applicationDidFinishLaunching` -- the latter returns long before any pixels exist,
    /// which is how apps end up publishing launch numbers they do not have.
    static func endLaunch(reason: StaticString = "first frame") {
        guard !hasReported, let startInstant else { return }
        hasReported = true

        let elapsed = ContinuousClock.now - startInstant

        if let intervalState {
            signposter.endInterval("launch", intervalState)
        }

        // 1e15 attoseconds == 1 millisecond.
        let ms =
            Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15

        // Gated on an environment variable rather than #if DEBUG, because the number that
        // matters is the Release one -- a debug build measures a floor we never ship.
        //   NIB_LAUNCH_TRACE=1 dist/Nib.app/Contents/MacOS/Nib
        if ProcessInfo.processInfo.environment["NIB_LAUNCH_TRACE"] != nil {
            let line = String(
                format: "[nib] launch -> %@: %.1f ms\n", String(describing: reason), ms)
            FileHandle.standardError.write(Data(line.utf8))
        }

        Logger(subsystem: "app.nib.Nib", category: "launch")
            .info("launch to \(String(describing: reason), privacy: .public): \(ms) ms")
    }
}
