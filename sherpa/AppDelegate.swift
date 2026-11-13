import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here, not by MenuBarController: the model outlives any one panel.
    private let state = AppState()
    // Held as a stored property: a local variable would deallocate when this
    // method returns, taking the status item (and its icon) down with it.
    private var menuBar: MenuBarController?
    private var hotkey: Hotkey?
    private var overlays: [OverlayWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(state: state)
        overlays = NSScreen.screens.map(OverlayWindow.init(screen:))
        overlays.forEach { $0.orderFrontRegardless() }
        let hotkey = Hotkey(state: state)
        self.hotkey = hotkey
        Task { await hotkey.start() }
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
