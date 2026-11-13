import AppKit
import ApplicationServices
import ImageIO

final class RecordingView: NSView {
    var downs = 0
    var ups = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
}

struct Overlay {
    let number: Int
    let bounds: CGRect
}

@main
enum CompanionCheck {
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
                await checkApp(pid: pid)
            } else if arguments.count == 3, arguments[1] == "--panel", let pid = Int32(arguments[2]) {
                await checkPanel(pid: pid)
            } else {
                checkPlacement()
            }
            exit(failures == 0 ? 0 : 1)
        }
        NSApp.run()
    }

    static func checkPlacement() {
        let one = [CGRect(x: 0, y: 0, width: 1710, height: 1112)]
        let two = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 97, y: -1112, width: 1710, height: 1112)]
        let rows: [(String, CGPoint, [CGRect], CGPoint)] = [
            ("middle of one display", CGPoint(x: 600, y: 400), one, CGPoint(x: 635, y: 375)),
            ("bottom-right corner clamps", CGPoint(x: 1709.5, y: 0.5), one, CGPoint(x: 1698, y: 12)),
            ("top-left corner, top row counts", CGPoint(x: 0, y: 1112), one, CGPoint(x: 35, y: 1087)),
            ("top row of the lower display", CGPoint(x: 500, y: 0), two, CGPoint(x: 535, y: -25)),
            ("bottom row of the upper display clamps", CGPoint(x: 500, y: 1), two, CGPoint(x: 535, y: 12)),
            ("right edge of the lower display clamps", CGPoint(x: 1800, y: -600), two, CGPoint(x: 1795, y: -625)),
            ("no screen holds the pointer", CGPoint(x: 5000, y: 5000), one, CGPoint(x: 5035, y: 4975)),
        ]
        for (label, pointer, screens, expected) in rows {
            let actual = Companion.position(following: pointer, on: screens)
            expect(actual == expected, label, "\(actual) vs \(expected)")
        }
        let lower = Companion.local(CGPoint(x: 535, y: -25), in: two[1])
        expect(lower == CGPoint(x: 438, y: 25), "local on the lower display", "\(lower)")
        let single = Companion.local(CGPoint(x: 635, y: 375), in: one[0])
        expect(single == CGPoint(x: 635, y: 737), "local on one display", "\(single)")
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }

    static func overlays(_ pid: Int32) -> [Overlay] {
        let level = Int(CGWindowLevelForKey(.screenSaverWindow))
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowOwnerPID as String] as? Int32 == pid,
                  window[kCGWindowLayer as String] as? Int == level,
                  let number = window[kCGWindowNumber as String] as? Int,
                  let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary)
            else { return nil }
            return Overlay(number: number, bounds: bounds)
        }
    }

    static func move(to point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func approach(_ target: CGPoint) async {
        for step in 0..<20 {
            move(to: CGPoint(x: target.x - 200 + CGFloat(step) * 10, y: target.y))
            try? await Task.sleep(for: .milliseconds(10))
        }
        move(to: target)
        try? await Task.sleep(for: .milliseconds(800))
    }

    static func glyph(in overlay: Overlay) -> (centre: CGPoint, count: Int)? {
        let path = NSTemporaryDirectory() + "companion-check-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l\(overlay.number)", path]
        guard (try? capture.run()) != nil else { return nil }
        capture.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 230 {
                sumX += Double(x) + 0.5
                sumY += Double(y) + 0.5
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let scale = Double(width) / overlay.bounds.width
        return (CGPoint(x: sumX / Double(count) / scale, y: sumY / Double(count) / scale), count)
    }

    static func near(_ a: CGPoint?, _ b: CGPoint, within tolerance: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func describe(_ point: CGPoint?) -> String {
        point.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "none"
    }

    static func checkApp(pid: Int32) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        let all = overlays(pid)
        for screen in NSScreen.screens {
            let id = displayID(screen)
            let b = CGDisplayBounds(id)
            guard let overlay = all.first(where: { $0.bounds == b }) else {
                expect(false, "display \(id): the app has an overlay", "\(all.map(\.bounds)) vs \(b)")
                continue
            }
            let others = all.filter { $0.number != overlay.number }

            for (fx, fy) in [(0.3, 0.4), (0.7, 0.6)] {
                let local = CGPoint(x: b.width * fx, y: b.height * fy)
                await approach(CGPoint(x: b.minX + local.x, y: b.minY + local.y))
                let found = glyph(in: overlay)?.centre
                expect(near(found, CGPoint(x: local.x + 35, y: local.y + 25), within: 2),
                       "display \(id): the glyph sits 35 right of and 25 below the pointer",
                       "\(describe(found)) vs \(describe(CGPoint(x: local.x + 35, y: local.y + 25)))")
                expect(others.allSatisfy { glyph(in: $0) == nil },
                       "display \(id): no other overlay shows the glyph")
            }

            move(to: CGPoint(x: b.maxX - 1, y: b.maxY - 1))
            try? await Task.sleep(for: .milliseconds(800))
            let corner = glyph(in: overlay)
            expect(near(corner?.centre, CGPoint(x: b.width - 12, y: b.height - 12), within: 2),
                   "display \(id): in the corner the glyph stays 12 pt inside both edges",
                   "\(describe(corner?.centre)) vs \(describe(CGPoint(x: b.width - 12, y: b.height - 12)))")

            try? await Task.sleep(for: .seconds(3))
            let later = glyph(in: overlay)
            expect(corner != nil && later != nil && near(later?.centre, corner!.centre, within: 0.5) && later?.count == corner?.count,
                   "display \(id): a still pointer leaves the glyph where it was",
                   "\(describe(corner?.centre)) x\(corner?.count ?? 0) then \(describe(later?.centre)) x\(later?.count ?? 0)")
        }

        await checkDrag(overlays: all)
        checkFeed(pid: pid)

        move(to: saved)
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func checkDrag(overlays all: [Overlay]) async {
        let main = CGMainDisplayID()
        guard let screen = NSScreen.screens.first(where: { displayID($0) == main }),
              let overlay = all.first(where: { $0.bounds == CGDisplayBounds(main) })
        else {
            expect(false, "the primary display has an overlay")
            return
        }
        let b = CGDisplayBounds(main)
        let target = RecordingView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let panel = NSPanel(
            contentRect: NSRect(x: screen.frame.midX - 200, y: screen.frame.midY - 150, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = target
        panel.orderFrontRegardless()
        defer { panel.close() }
        try? await Task.sleep(for: .milliseconds(300))

        let start = CGPoint(x: b.midX, y: b.midY)
        func post(_ type: CGEventType, at point: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.leftMouseDown, at: start)
        try? await Task.sleep(for: .milliseconds(20))
        var end = start
        for _ in 0..<10 {
            end.x += 15
            post(.leftMouseDragged, at: end)
            try? await Task.sleep(for: .milliseconds(20))
        }
        post(.leftMouseUp, at: end)
        try? await Task.sleep(for: .milliseconds(800))

        expect(target.downs == 1 && target.ups == 1, "the drag stayed in the check's window",
               "down \(target.downs) up \(target.ups)")
        let local = CGPoint(x: end.x - b.minX + 35, y: end.y - b.minY + 25)
        let found = glyph(in: overlay)?.centre
        expect(near(found, local, within: 2), "the glyph followed the drag", "\(describe(found)) vs \(describe(local))")
    }

    static func checkFeed(pid: Int32) {
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["show", "--last", "2m", "--style", "syslog", "--predicate",
                         "processIdentifier == \(pid) AND subsystem == \"my.rooftop.sherpa\" AND category == \"companion\""]
        let pipe = Pipe()
        log.standardOutput = pipe
        log.standardError = FileHandle.nullDevice
        var text = ""
        if (try? log.run()) != nil {
            text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            log.waitUntilExit()
        }
        expect(text.contains("companion tapping"), "the companion follows through the event tap, not the poll", text)
    }

    static func panelFrame(pid: Int32) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let window = (windows as? [AXUIElement])?.first
        else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func checkPanel(pid: Int32) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        guard let frame = panelFrame(pid: pid) else {
            expect(false, "the panel frame is readable through Accessibility")
            return
        }
        move(to: CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(for: .milliseconds(300))
        let target = CGPoint(x: frame.midX - 60, y: frame.midY)
        move(to: target)
        try? await Task.sleep(for: .milliseconds(800))

        let all = overlays(pid)
        let display = NSScreen.screens.map(displayID).first { CGDisplayBounds($0).contains(target) }
        if let display, let overlay = all.first(where: { $0.bounds == CGDisplayBounds(display) }) {
            let b = overlay.bounds
            let expected = CGPoint(x: target.x - b.minX + 35, y: target.y - b.minY + 25)
            let found = glyph(in: overlay)?.centre
            expect(near(found, expected, within: 2), "over the panel, the glyph still follows",
                   "\(describe(found)) vs \(describe(expected))")
        } else {
            expect(false, "over the panel, the glyph still follows", "no overlay on the display holding \(target)")
        }

        move(to: saved)
        try? await Task.sleep(for: .milliseconds(300))
    }
}
