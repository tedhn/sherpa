import AppKit

final class RecordingView: NSView {
    var downs = 0
    var ups = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
}

final class PaintedView: NSView {
    var downs = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemPink.setFill()
        NSRect(x: bounds.midX - 80, y: bounds.midY - 80, width: 160, height: 160).fill()
        let stroke: CGFloat = 4
        for edge in [
            NSRect(x: 0, y: 0, width: bounds.width, height: stroke),
            NSRect(x: 0, y: bounds.height - stroke, width: bounds.width, height: stroke),
            NSRect(x: 0, y: 0, width: stroke, height: bounds.height),
            NSRect(x: bounds.width - stroke, y: 0, width: stroke, height: bounds.height),
        ] {
            edge.fill()
        }
    }
    override func mouseDown(with event: NSEvent) { downs += 1 }
}

@main
enum OverlayCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String, _ actual: @autoclosure () -> String = "") {
        print(ok ? "  ok   \(what)" : "  FAIL \(what): \(actual())")
        if !ok { failures += 1 }
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        Task {
            if arguments.count == 3, arguments[1] == "--app", let pid = Int32(arguments[2]) {
                checkApp(pid: pid)
            } else {
                await checkWindows()
            }
            exit(failures == 0 ? 0 : 1)
        }
        NSApp.run()
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    static func bounds(_ window: [String: Any]) -> CGRect? {
        (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    static func click(at point: CGPoint) async {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    static func checkWindows() async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        defer { CGWarpMouseCursorPosition(saved) }

        for screen in NSScreen.screens {
            let id = displayID(screen)
            let displayBounds = CGDisplayBounds(id)
            let centre = CGPoint(x: displayBounds.midX, y: displayBounds.midY)

            let overlay = OverlayWindow(screen: screen)
            let painted = PaintedView(frame: NSRect(origin: .zero, size: screen.frame.size))
            overlay.contentView = painted

            let target = RecordingView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            let panel = NSPanel(
                contentRect: NSRect(x: screen.frame.midX - 150, y: screen.frame.midY - 150, width: 300, height: 300),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.contentView = target

            panel.orderFrontRegardless()
            overlay.orderFrontRegardless()
            defer {
                overlay.close()
                panel.close()
            }

            await waitUntil { onScreenWindows().contains { $0[kCGWindowNumber as String] as? Int == overlay.windowNumber } }
            let info = onScreenWindows().first { $0[kCGWindowNumber as String] as? Int == overlay.windowNumber }
            expect(info != nil, "display \(id): the overlay is on screen")
            let layer = info?[kCGWindowLayer as String] as? Int
            expect(layer == Int(CGWindowLevelForKey(.screenSaverWindow)),
                   "display \(id): the overlay sits at the screen saver level", "layer \(String(describing: layer))")
            let frame = info.flatMap(bounds)
            expect(frame == displayBounds, "display \(id): the overlay covers the display",
                   "\(String(describing: frame)) vs \(displayBounds)")

            await click(at: centre)
            await waitUntil { target.downs >= 1 && target.ups >= 1 }
            expect(target.downs == 1 && target.ups == 1, "display \(id): a click through the painted square reaches the window beneath",
                   "down \(target.downs) up \(target.ups)")
            expect(painted.downs == 0, "display \(id): the overlay received no click", "\(painted.downs) clicks")
            expect(!overlay.isKeyWindow, "display \(id): the overlay is not the key window")
        }
    }

    static func checkApp(pid: Int32) {
        let level = Int(CGWindowLevelForKey(.screenSaverWindow))
        let frames = onScreenWindows()
            .filter { $0[kCGWindowOwnerPID as String] as? Int32 == pid && $0[kCGWindowLayer as String] as? Int == level }
            .compactMap { bounds($0) }
        let displays = NSScreen.screens.map { CGDisplayBounds(displayID($0)) }
        expect(frames.count == displays.count, "the app has one overlay per screen", "\(frames.count) overlays, \(displays.count) screens")
        expect(Set(frames.map(\.debugDescription)) == Set(displays.map(\.debugDescription)), "the overlays cover exactly the displays", "\(frames) vs \(displays)")
    }
}
