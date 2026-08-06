// Post a real mouse click at a screen point.
//
// System Events' `click at` returns -25208 here and, worse, aborts the rest of the script when it
// does — which is how two clips ended up silently truncated. CGEvent has no such restriction.
import AppKit
import CoreGraphics

_ = NSApplication.shared
let args = CommandLine.arguments
guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("usage: click <x> <y>\n".utf8)); exit(2)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType) {
    guard
        let event = CGEvent(
            mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
            mouseButton: .left)
    else { return }
    // Say "this is the first click of a sequence" explicitly. Left unset, successive synthetic
    // clicks a couple of seconds apart were being counted as one continuing multi-click, and the
    // third one in a row was swallowed: the control took the hover but never changed selection.
    if type != .mouseMoved {
        event.setIntegerValueField(.mouseEventClickState, value: 1)
    }
    event.post(tap: .cghidEventTap)
}

// Approach in two steps. A single jump straight onto the control was landing often enough to look
// fine and failing often enough to ruin a take: the control took the hover but not the click. An
// intermediate move gives the view's tracking areas a mouse-moved event to process before the one
// that matters.
func move(to intermediate: CGPoint) {
    CGEvent(
        mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: intermediate,
        mouseButton: .left)?.post(tap: .cghidEventTap)
}

move(to: CGPoint(x: x - 40, y: y + 60))
usleep(120_000)
post(.mouseMoved)
usleep(250_000)
post(.leftMouseDown)
usleep(90_000)
post(.leftMouseUp)
usleep(50_000)
