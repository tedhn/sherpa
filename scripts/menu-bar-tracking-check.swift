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
//   outside-click  panel open. Posts a real mouse click at the panel's centre
//                  and then one on a window of its own, and expects only the
//                  second to close the panel.
//
// The clicking modes post CGEvents. System Events' click is an accessibility
// press on whichever element sits at a point, not a mouse event, and a global
// monitor is never called for one, so the modes above exercise nothing about
// the monitor. They also bring the window they click, because no pixel of the
// main display is left uncovered by the person's own windows: there is no bare
// desktop to click and their editor is not ours to click into.

enum Mode: String {
    case toggle
    case quit
    case outsideClick = "outside-click"
}

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = Mode(rawValue: arguments.first ?? "toggle") ?? .toggle
guard let pid = arguments.dropFirst().first.flatMap(Int32.init) else {
    print("  FAIL no process id given")
    exit(1)
}

// A running NSApplication, not a bare RunLoop: this process puts a window of
// its own on screen, and AppKit only services one from the application's event
// loop. Accessory so that window costs the person no Dock icon and no app
// switcher entry.
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

/// The display `point` is on. The menu bar follows the pointer between displays,
/// so neither the panel nor the icon is reliably on the primary one.
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

// Addressed by process id for the same reason the shell script is: a copy
// launched from Xcode is also called sherpa.
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

/// A window of the check's own, put where the person has nothing, so an outside
/// click lands somewhere it can do no harm. Non-activating so it pulls the front
/// app away no more than the click already does.
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

/// Read here, immediately before the click that uses it, rather than handed in
/// by the shell: the menu bar follows the pointer between displays, so a rect
/// measured before an earlier open can describe a place the panel no longer is,
/// and a click posted there lands on the person's own windows instead.
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

// Through the application's event loop and never usleep: distributed
// notifications and posted mouse events both arrive on the run loop, so a
// blocked main thread reads exactly like a feature that does not work.
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
    // Clear of the panel on the vertical axis alone, so nothing about where the
    // panel sits horizontally can end up putting the target underneath it.
    let screen = display(containing: CGPoint(x: panelRect.midX, y: panelRect.midY))
    let targetPoint = CGPoint(x: screen.midX, y: (panelRect.maxY + screen.maxY) / 2)
    let target = showClickTarget(centredAt: targetPoint)
    settle(0.5)

    let inside = record { postClick(at: CGPoint(x: panelRect.midX, y: panelRect.midY)) }
    let afterInside = windowCount()
    let outside = record { postClick(at: targetPoint) }
    let afterOutside = windowCount()
    let afterwards = record { postClick(at: targetPoint) }
    target.orderOut(nil)

    guard afterInside == "1" else {
        print("  FAIL a real click inside the panel closed it, recorded \(inside)")
        exit(1)
    }
    // Hiding and re-showing would leave the window count alone and record this.
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
    // The window count reads the same whether the pin came back once, not at
    // all, or twice, and two strand the menu bar for every app on the system.
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
}
