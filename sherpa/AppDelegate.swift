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
}
