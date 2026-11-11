import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here, not by MenuBarController: the model outlives any one panel.
    private let state = AppState()
    // Held as a stored property: a local variable would deallocate when this
    // method returns, taking the status item (and its icon) down with it.
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(state: state)
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
