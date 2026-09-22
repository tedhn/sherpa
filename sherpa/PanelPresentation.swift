import AppKit

// Everything a visible panel owes the world outside this process, claimed in
// init and handed back in deinit, so the pairing is an object's lifetime rather
// than a rule every call site has to remember. There is deliberately no end()
// or stop(): an operation that can be called is an operation that can be called
// twice, and a second MenuBarReveal.release() strands the menu bar for every
// app on the system.
@MainActor
final class PanelPresentation {
    private let monitor: Any?

    init(onOutsideClick: @escaping () -> Void) {
        MenuBarReveal.hold()
        // Mouse down, not mouse up: a menu closes the instant you press
        // elsewhere.
        //
        // The handler filters nothing and captures nothing it could filter on.
        // AppKit never calls a global monitor for an event delivered to our own
        // app, which measurably covers both a click on this panel and a click
        // on our own status item, so "the global monitor fired" already means
        // "outside" and any frame test would be dead code. The day that stops
        // being true, the icon-click mode in scripts/menu-bar-tracking-check.swift
        // is what says so.
        //
        // A nil token is a documented outcome rather than an error: the panel
        // still shows and the pin is still balanced, and only dismissal is lost.
        // Nothing here may block showing the panel.
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in onOutsideClick() }
    }

    // Only ever released on the main actor, because only main-actor code holds
    // it; assumeIsolated is what lets a nonisolated deinit say so in a module
    // that defaults to main-actor isolation.
    deinit {
        MainActor.assumeIsolated {
            // Deliveries stop before the pin goes back, so no handler can run
            // on behalf of a presentation that has already given it up.
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            MenuBarReveal.release()
        }
    }
}
