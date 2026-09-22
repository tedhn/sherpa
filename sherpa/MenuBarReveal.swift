import Foundation

// Over a fullscreen app macOS hides the menu bar and slides it away again once
// the pointer leaves the top edge, which would leave the panel floating under
// nothing. The system pins the bar for as long as a menu is tracking. HIToolbox
// broadcasts the start and the end of that tracking as distributed
// notifications, and Dock.app holds the bar in response. This panel is not a
// menu, so it posts the same pair to claim the same pin.
//
// The notification names are undocumented. If one ever stops being honored the
// failure is silent, and the cost is only a retracted menu bar, so nothing here
// may block showing the panel.
//
// The pin is held by another process, so every hold() needs exactly one
// release(). An unbalanced hold pins the menu bar for every app on the system
// until the next real menu opens.
enum MenuBarReveal {
    static func hold() {
        post("com.apple.HIToolbox.beginMenuTrackingNotification")
    }

    static func release() {
        post("com.apple.HIToolbox.endMenuTrackingNotification")
    }

    private static func post(_ name: String) {
        // The App Sandbox drops a distributed notification that carries a
        // userInfo dictionary. This app is not sandboxed yet, so the post stays
        // bare to survive the day it is.
        DistributedNotificationCenter.default().post(name: Notification.Name(name), object: nil)
    }
}
