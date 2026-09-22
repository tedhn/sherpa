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
//   toggle  panel closed. Opens it, closes it, expects begin then end.
//   quit    panel open. Quits the app, expects end.

enum Mode: String {
    case toggle
    case quit
}

let arguments = Array(CommandLine.arguments.dropFirst())
let mode = Mode(rawValue: arguments.first ?? "toggle") ?? .toggle
guard let pid = arguments.dropFirst().first.flatMap(Int32.init) else {
    print("  FAIL no process id given")
    exit(1)
}

var recorded: [String] = []
for kind in ["begin", "end"] {
    DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.HIToolbox.\(kind)MenuTrackingNotification"),
        object: nil,
        queue: .main
    ) { _ in recorded.append(kind) }
}

func run(_ arguments: [String]) {
    let osascript = Process()
    osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osascript.arguments = arguments
    osascript.standardOutput = FileHandle.nullDevice
    osascript.standardError = FileHandle.nullDevice
    try? osascript.run()
    osascript.waitUntilExit()
}

func clickStatusItem() {
    run([
        "-e",
        "tell application \"System Events\" to tell (first process whose unix id is \(pid)) "
            + "to click menu bar item 1 of menu bar 2",
    ])
}

// terminate() sends the quit Apple event to one process. Not a signal: SIGTERM
// skips applicationWillTerminate, which is exactly the path that strands the pin.
func quitApp() {
    NSRunningApplication(processIdentifier: pid)?.terminate()
}

let window: TimeInterval = 1.5

func settle(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
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
}
