import AppKit

// Claims what a visible panel owes the world outside this process, and hands it
// back when the object dies. There is deliberately no end() or stop(): an
// operation that can be called is an operation that can be called twice, and a
// second MenuBarReveal.release() strands the menu bar for every app on the
// system.
@MainActor
final class PanelPresentation {
    private let monitor: Any?

    init(onOutsideClick: @escaping () -> Void) {
        MenuBarReveal.hold()
        // The handler filters nothing on purpose. AppKit never calls a global
        // monitor for an event delivered to our own app, measured here to cover
        // a click on this panel and on our own status item alike, so a frame
        // test would be dead code. The icon-click mode in
        // scripts/menu-bar-tracking-check.swift is what fails if that changes.
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in onOutsideClick() }
    }

    isolated deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        MenuBarReveal.release()
    }
}
