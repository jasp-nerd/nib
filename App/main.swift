import AppKit

// Deliberately not `@main struct Nib: SwiftUI.App`.
//
// Two reasons, both load-bearing:
//   1. The SwiftUI scene graph costs measurable launch time we do not need to spend. The
//      window, split view and menu are all things we want to control directly anyway.
//   2. The response body text view has to be a real AppKit NSTextView inside a real
//      NSViewController -- TextKit 2 rendering attributes are unreliable when the view is
//      wrapped in NSViewRepresentable. Owning the window with NSSplitViewController keeps
//      that path clean rather than fighting it later.
//
// SwiftUI is still used for essentially all *content*, hosted in NSHostingController.

LaunchMetrics.beginLaunch()

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
