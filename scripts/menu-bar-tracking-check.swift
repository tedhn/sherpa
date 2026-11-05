import AppKit

// Records the menu-bar tracking notifications the app broadcasts. macOS pins
// the menu bar over a fullscreen app for as long as a menu is tracking, and
// these are the notifications it keys on, so the panel has to claim and release
// the same pin. The pin lives in another process, so an unreleased one strands
// the menu bar for every app on the system.
//
// These notifications carry no sender. A real menu opening in any other app
// posts object=nil and userInfo=nil, exactly as this app does, so a recording
// cannot be attributed to one process. The check therefore listens to a quiet
// window first and refuses to measure if anything arrives during it.
//
// Takes a mode and the process id of the app to drive. The process id matters:
// a copy launched from Xcode is also called sherpa, and addressing the app by
// name would pick one of them at random.
//   toggle         panel closed. Opens it, closes it, expects begin then end.
//   quit           panel open. Quits the app, expects end.
//   outside-click  panel open. Posts a real mouse click on the panel's title
//                  and then one on a window of its own, and expects only the
//                  second to close the panel.
//   icon-click     panel open. Posts a real mouse click on the status item and
//                  expects the panel closed having recorded exactly one end.
//
// The clicking modes post CGEvents. System Events' click is an accessibility
// press on whichever element sits at a point, not a mouse event, and a global
// monitor is never called for one, so the modes above exercise nothing about
// the monitor. They bring the window they click, because no pixel of the main
// display is left uncovered by the person's own windows.

enum Mode: String {
    case toggle
    case quit
    case outsideClick = "outside-click"
    case iconClick = "icon-click"
}

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = Mode(rawValue: arguments.first ?? "toggle") ?? .toggle
guard let pid = arguments.dropFirst().first.flatMap(Int32.init) else {
    print("  FAIL no process id given")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

// Accessibility and CGEvent share one coordinate space, origin top-left with y
// growing downward. AppKit screen coordinates grow upward from the bottom-left
// of the primary display, and only the click target is placed in those.
let primary = NSScreen.screens.first?.frame ?? .zero

func toAppKit(_ point: CGPoint) -> CGPoint {
    CGPoint(x: point.x, y: primary.height - point.y)
}

func toAccessibility(_ frame: CGRect) -> CGRect {
    CGRect(x: frame.minX, y: primary.height - frame.maxY, width: frame.width, height: frame.height)
}

func display(containing point: CGPoint) -> CGRect {
    NSScreen.screens.map { toAccessibility($0.frame) }.first { $0.contains(point) }
        ?? toAccessibility(primary)
}

var recorded: [String] = []
for kind in ["begin", "end"] {
    DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.HIToolbox.\(kind)MenuTrackingNotification"),
        object: nil,
        queue: .main
    ) { _ in recorded.append(kind) }
}

func osascript(_ source: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func driven(_ command: String) -> String {
    osascript(
        "tell application \"System Events\" to tell (first process whose unix id is \(pid)) to \(command)"
    )
}

func clickStatusItem() {
    _ = driven("click menu bar item 1 of menu bar 2")
}

func windowCount() -> String {
    driven("return count of windows")
}

func postClick(at point: CGPoint) {
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        settle(0.05)
    }
}

func showClickTarget(centredAt point: CGPoint) -> NSPanel {
    let side: CGFloat = 60
    let centre = toAppKit(point)
    let target = NSPanel(
        contentRect: NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    target.level = .statusBar
    target.backgroundColor = .systemBlue
    target.orderFrontRegardless()
    return target
}

/// Read immediately before the click that uses it, never handed in by the
/// shell: the menu bar follows the pointer between displays, so a rect measured
/// an open or two earlier can describe a place the panel no longer is.
func rect(of element: String) -> CGRect? {
    let numbers = (driven("return position of \(element)") + "," + driven("return size of \(element)"))
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard numbers.count == 4 else { return nil }
    return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
}

// terminate() sends the quit Apple event to one process. Not a signal: SIGTERM
// skips applicationWillTerminate, which is exactly the path that strands the pin.
func quitApp() {
    NSRunningApplication(processIdentifier: pid)?.terminate()
}

let window: TimeInterval = 1.5

// Through the event loop and never usleep: notifications and posted clicks both
// arrive on the run loop, so a blocked main thread reads as a broken feature.
func settle(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while let event = app.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        app.sendEvent(event)
    }
}

/// Runs one action and returns what arrived while it settled.
func record(_ action: () -> Void) -> [String] {
    recorded.removeAll()
    action()
    settle(window)
    return recorded
}

func unmeasurable(_ reason: String) -> Never {
    print("  skip \(mode.rawValue) pin check: \(reason)")
    exit(0)
}

let quiet = record {}
guard quiet.isEmpty else {
    unmeasurable("another app opened a menu during the control window, so nothing can be attributed")
}

switch mode {
case .toggle:
    let opening = record(clickStatusItem)
    guard opening.contains("begin") else {
        print("  FAIL opening the panel broadcast \(opening), expected begin")
        exit(1)
    }
    let closing = record(clickStatusItem)
    guard closing.contains("end") else {
        print("  FAIL closing the panel broadcast \(closing), expected end")
        exit(1)
    }
    guard opening == ["begin"], closing == ["end"] else {
        unmeasurable("another app opened a menu mid-check, recorded \(opening) then \(closing)")
    }
    print("  ok   opening and closing the panel claims and releases the pin")
case .quit:
    let quitting = record(quitApp)
    guard quitting.contains("end") else {
        print("  FAIL quitting with the panel open broadcast \(quitting), expected end")
        exit(1)
    }
    guard quitting == ["end"] else {
        unmeasurable("another app opened a menu mid-check, recorded \(quitting)")
    }
    print("  ok   quitting with the panel open releases the pin")
case .outsideClick:
    guard let panelRect = rect(of: "window 1") else {
        unmeasurable("the panel closed before the check clicked it, someone is using the machine")
    }
    let screen = display(containing: CGPoint(x: panelRect.midX, y: panelRect.midY))
    let targetPoint = CGPoint(x: screen.midX, y: (panelRect.maxY + screen.maxY) / 2)
    let target = showClickTarget(centredAt: targetPoint)
    settle(0.5)

    guard let titleRect = rect(of: "static text 1 of group 1 of window 1") else {
        unmeasurable("the panel closed before the check clicked it, someone is using the machine")
    }
    let inside = record { postClick(at: CGPoint(x: titleRect.midX, y: titleRect.midY)) }
    let afterInside = windowCount()
    let outside = record { postClick(at: targetPoint) }
    let afterOutside = windowCount()
    let afterwards = record { postClick(at: targetPoint) }
    target.orderOut(nil)

    guard afterInside == "1" else {
        print("  FAIL a real click inside the panel closed it, recorded \(inside)")
        exit(1)
    }
    guard inside.first != "end" else {
        print("  FAIL a real click inside the panel released the pin, recorded \(inside)")
        exit(1)
    }
    guard inside.isEmpty else {
        unmeasurable("another app opened a menu over the inside click, recorded \(inside)")
    }
    guard afterOutside == "0" else {
        print("  FAIL a real click outside the panel left it open, recorded \(outside)")
        exit(1)
    }
    guard outside.first == "end" else {
        print("  FAIL a click outside the panel broadcast \(outside), expected end")
        exit(1)
    }
    guard outside.dropFirst().first != "end" else {
        print("  FAIL a click outside the panel released the pin twice, recorded \(outside)")
        exit(1)
    }
    guard afterwards.first != "end" else {
        print("  FAIL a click with the panel already closed released the pin, recorded \(afterwards)")
        exit(1)
    }
    guard outside == ["end"], afterwards.isEmpty else {
        unmeasurable("another app opened a menu mid-check, recorded \(outside) then \(afterwards)")
    }
    print("  ok   a real click outside closes the panel and releases the pin exactly once")
case .iconClick:
    // Stands in for the filtering the monitor deliberately does not do. If our
    // own status item click ever reaches our own global monitor, the monitor
    // hides the panel and the button action re-shows it, so the panel ends open
    // having recorded ["end", "begin"]. The toggle mode cannot see that, because
    // an accessibility press is not a mouse event.
    guard rect(of: "window 1") != nil else {
        unmeasurable("the panel closed before the check clicked the icon, someone is using the machine")
    }
    guard let itemRect = rect(of: "menu bar item 1 of menu bar 2") else {
        unmeasurable("the status item could not be measured, so there is nothing to aim at")
    }
    let centre = CGPoint(x: itemRect.midX, y: itemRect.midY)
    let cursor = CGEvent(source: nil)?.location ?? centre
    // The menu bar tracks the pointer, and a click posted at an item the pointer
    // is not over misses it, so the cursor goes there first and back afterwards.
    let clicking = record {
        CGWarpMouseCursorPosition(centre)
        settle(0.3)
        postClick(at: centre)
    }
    CGWarpMouseCursorPosition(cursor)
    let afterClicking = windowCount()

    guard afterClicking == "0" else {
        print("  FAIL a real click on the icon left the panel open, recorded \(clicking)")
        exit(1)
    }
    guard clicking.first == "end" else {
        print("  FAIL a real click on the icon broadcast \(clicking), expected end")
        exit(1)
    }
    guard clicking == ["end"] else {
        unmeasurable("another app opened a menu mid-check, recorded \(clicking)")
    }
    print("  ok   a real click on the icon closes the panel and releases the pin once")
}
