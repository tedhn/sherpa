import AppKit

// Records the menu-bar tracking notifications the app broadcasts. macOS pins
// the menu bar over a fullscreen app for as long as a menu is tracking, and
// these are the notifications it keys on, so the panel has to claim and release
// the same pin. The pin lives in another process, so an unreleased one strands
// the menu bar for every app on the system.
//
// Two modes, both assuming sherpa is running.
//   toggle  panel closed. Opens it, closes it, expects begin then end.
//   quit    panel open. Quits the app, expects end.

enum Mode: String {
    case toggle
    case quit
}

let mode = Mode(rawValue: CommandLine.arguments.dropFirst().first ?? "toggle") ?? .toggle

var recorded: [String] = []
for (name, label) in [("begin", "begin"), ("end", "end")] {
    DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.HIToolbox.\(name)MenuTrackingNotification"),
        object: nil,
        queue: .main
    ) { _ in recorded.append(label) }
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
    run(["-e", "tell application \"System Events\" to tell process \"sherpa\" to click menu bar item 1 of menu bar 2"])
}

// The quit Apple event, not a signal. SIGTERM skips applicationWillTerminate,
// which is exactly the path that would strand the pin.
func quitApp() {
    run(["-e", "tell application id \"my.rooftop.sherpa\" to quit"])
}

func settle(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

settle(0.5)
recorded.removeAll()

let expected: [String]
switch mode {
case .toggle:
    clickStatusItem()
    settle(1.5)
    guard recorded == ["begin"] else {
        print("  FAIL opening the panel must broadcast begin, got \(recorded)")
        exit(1)
    }
    clickStatusItem()
    settle(1.5)
    expected = ["begin", "end"]
case .quit:
    quitApp()
    settle(2.0)
    expected = ["end"]
}

print("  info \(mode.rawValue) sequence: \(recorded.isEmpty ? "(nothing broadcast)" : recorded.joined(separator: ", "))")
guard recorded == expected else {
    print("  FAIL expected \(expected), got \(recorded)")
    exit(1)
}
print("  ok   \(mode == .toggle ? "opening and closing the panel claims and releases the pin" : "quitting with the panel open releases the pin")")
