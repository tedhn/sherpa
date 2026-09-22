import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Held as a stored property: a local variable here would deallocate
    // the item when the method returns, and the icon would vanish.
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "mountain.2.fill",
            accessibilityDescription: "Sherpa"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Sherpa",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu

        statusItem = item
    }
}
