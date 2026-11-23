import AppKit
import os
import SwiftUI

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "overlay")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here, not by MenuBarController: the model outlives any one panel.
    private let state = AppState()
    // Held as a stored property: a local variable would deallocate when this
    // method returns, taking the status item (and its icon) down with it.
    private var menuBar: MenuBarController?
    private var hotkey: Hotkey?
    private var companion: Companion?
    private var overlays: [OverlayWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.openMicrophone()
        menuBar = MenuBarController(state: state)
        let companion = Companion()
        self.companion = companion
        rebuildOverlays()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        Task { await companion.start() }
        let hotkey = Hotkey(state: state, pen: Pen(state: state))
        self.hotkey = hotkey
        Task { await hotkey.start() }
    }

    @objc private func screensChanged() {
        rebuildOverlays()
    }

    private func rebuildOverlays() {
        guard let companion else { return }
        let old = overlays
        overlays = NSScreen.screens.map { screen in
            let overlay = OverlayWindow(screen: screen)
            let content = NSHostingView(rootView: CompanionView(companion: companion, state: state, screenFrame: screen.frame))
            // A hosting view sizes its window to the content by default; the overlay must stay the screen's size.
            content.sizingOptions = []
            overlay.contentView = content
            return overlay
        }
        overlays.forEach { $0.orderFrontRegardless() }
        old.forEach { $0.close() }
        // A removed display makes macOS move the pointer, and a move with no event is missed.
        companion.followPointer()
        logger.notice("overlays rebuilt screens=\(self.overlays.count)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // With .terminateLater, applicationWillTerminate waits for the reply, so hiding the
        // panel is what releases the menu bar pin before the wait on the network.
        menuBar?.hidePanel()
        Task {
            let (done, finish) = AsyncStream<Void>.makeStream()
            Task {
                await state.quit()
                finish.yield()
            }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                finish.yield()
            }
            for await _ in done { break }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
