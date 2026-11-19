import AppKit

final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // The default behaviour zooms a new window in from 98 % over about 300 ms, overshooting
        // the screen by a point before settling. An overlay should just be there.
        animationBehavior = .none
        ignoresMouseEvents = true
        level = .screenSaver
        // .stationary keeps the window out of Mission Control's shuffle.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        isRestorable = false
        // Otherwise System Events counts the overlay as the process's window 1,
        // ahead of the panel, and VoiceOver and every window 1 lookup in the
        // verify scripts would read the overlay.
        setAccessibilityElement(false)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
