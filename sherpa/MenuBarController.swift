import AppKit
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let state: AppState
    // Assigned, never read. Not a second visibility flag: panel.isVisible stays
    // the single source of truth for that, and this answers what the app owes.
    private var presentation: PanelPresentation?

    init(state: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.state = state
        panel = FloatingPanel(contentView: NSHostingView(rootView: ContentView(state: state)))
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "mountain.2.fill", accessibilityDescription: "Sherpa")
        button.target = self
        button.action = #selector(statusItemClicked)
        // A status item button's default trigger is left-mouse-down only;
        // without this, a right-click never reaches the action.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // statusItem.menu is deliberately left unset: assigning one makes
        // AppKit pop it on click and skip the action entirely, which is the
        // opposite of the left-click-toggles-panel behavior this exists for.
    }

    // The panel can still be open at quit, and the menu bar pin outlives this
    // process. FluidMenuBarExtra releases its pin from windowDidResignKey, which
    // is not an option here. becomesKeyOnlyIfNeeded plus orderFrontRegardless
    // means the panel usually never becomes key, so it never resigns key either.
    @objc private func applicationWillTerminate(_ notification: Notification) {
        presentation = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsQuitMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if wantsQuitMenu {
            showQuitMenu(from: sender)
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main
        else { return }

        // Re-measure so a content change re-anchors the panel for free.
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setContentSize(size)

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = PanelAnchor.origin(for: size, under: buttonFrame, within: screen.visibleFrame)
        panel.setFrameOrigin(origin)

        // Below the guards, so one that bails out cannot leave a pin claimed or
        // a monitor installed with no panel to hand either back.
        presentation = PanelPresentation { [weak self] in self?.outsideClick() }
        // orderFrontRegardless, not makeKeyAndOrderFront: AppKit can suppress a
        // plain order-front for an app that is not active, and this app never
        // activates. Making the panel key here would pull focus as well.
        panel.orderFrontRegardless()
    }

    private func outsideClick() {
        if case .askingForAccess = state.microphone { return }
        hidePanel()
    }

    private func hidePanel() {
        // orderOut, not close(): close() tears down the hosting view (and the
        // SwiftUI state inside it); orderOut just hides it for the next show.
        panel.orderOut(nil)
        presentation = nil
    }

    private func showQuitMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Sherpa",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }
}
