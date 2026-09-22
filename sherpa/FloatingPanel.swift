import AppKit

final class FloatingPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
            // .nonactivatingPanel is an NSPanel-only style. NSWindow has no
            // such mask, and showing one would activate the app.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // A window with no fill of its own. Because it is not opaque, the
        // window server derives the shadow from the content's alpha, so
        // SwiftUI's rounded background casts a rounded shadow rather than the
        // window frame casting a rectangular one.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        becomesKeyOnlyIfNeeded = true
        // NSPanel defaults this to true, which would hide the panel the moment
        // the app behind it takes focus back.
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // Otherwise macOS restores the panel on the next launch if it happened
        // to be open at quit, and the app starts with a panel nobody opened.
        isRestorable = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
        self.contentView = contentView
    }

    // Borderless windows return false here by default, which silently eats
    // keystrokes in any text field. becomesKeyOnlyIfNeeded above narrows the
    // grant to views that ask for the keyboard, so clicking a button never
    // pulls focus from the app in front.
    override var canBecomeKey: Bool { true }
}
