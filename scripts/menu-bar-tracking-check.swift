import AppKit

// Opens and closes the panel and records the menu-bar tracking notifications
// the app broadcasts. macOS pins the menu bar over a fullscreen app for as
// long as a menu is tracking, and these are the notifications it keys on, so
// the panel has to claim and release the same pin.
//
// Assumes sherpa is already running with the panel closed. Prints the
// recorded sequence and exits non-zero if it is not begin then end.

let beginTracking = Notification.Name("com.apple.HIToolbox.beginMenuTrackingNotification")
let endTracking = Notification.Name("com.apple.HIToolbox.endMenuTrackingNotification")

var recorded: [String] = []
for (name, label) in [(beginTracking, "begin"), (endTracking, "end")] {
    DistributedNotificationCenter.default().addObserver(
        forName: name, object: nil, queue: .main
    ) { _ in recorded.append(label) }
}

func clickStatusItem() {
    let osascript = Process()
    osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osascript.arguments = [
        "-e",
        "tell application \"System Events\" to tell process \"sherpa\" to click menu bar item 1 of menu bar 2",
    ]
    osascript.standardOutput = FileHandle.nullDevice
    osascript.standardError = FileHandle.nullDevice
    try? osascript.run()
    osascript.waitUntilExit()
}

func settle(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

settle(0.5)
recorded.removeAll()

clickStatusItem()
settle(1.5)
let afterOpen = recorded

clickStatusItem()
settle(1.5)
let afterClose = recorded

print("  info sequence: \(recorded.isEmpty ? "(nothing broadcast)" : recorded.joined(separator: ", "))")
guard afterOpen == ["begin"], afterClose == ["begin", "end"] else {
    print("  FAIL opening the panel must broadcast begin, closing must broadcast end")
    exit(1)
}
print("  ok   the panel claims and releases the menu bar pin")
