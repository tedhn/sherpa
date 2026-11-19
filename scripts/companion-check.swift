import AppKit
import ApplicationServices
import ImageIO
import SwiftUI

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

enum Seen: String { case none, arrow, waveform, spinner, unknown }

struct Pixels {
    var rgba: [UInt8]
    var width: Int
    var height: Int
}

func decode(_ image: CGImage) -> Pixels? {
    let width = image.width
    let height = image.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? Pixels(rgba: rgba, width: width, height: height) : nil
}

/// Opaque pixels inside the 40 x 40 pt square around `centre`, as a column mask and a count of
/// the pixels within 2.5 pt of the centre.
func opaqueColumns(_ rgba: [UInt8], width: Int, height: Int, scale: Double, centre: CGPoint)
    -> (columns: [Bool], first: Int, count: Int, nearCentre: Int)
{
    let x0 = max(0, Int(((centre.x - 20) * scale).rounded()))
    let x1 = min(width, Int(((centre.x + 20) * scale).rounded()))
    let y0 = max(0, Int(((centre.y - 20) * scale).rounded()))
    let y1 = min(height, Int(((centre.y + 20) * scale).rounded()))
    var columns = [Bool](repeating: false, count: max(0, x1 - x0))
    var count = 0
    var nearCentre = 0
    let reach = 2.5 * scale
    for y in y0..<max(y0, y1) {
        for x in x0..<max(x0, x1) where rgba[(y * width + x) * 4 + 3] >= 230 {
            columns[x - x0] = true
            count += 1
            let dx = Double(x) + 0.5 - centre.x * scale
            let dy = Double(y) + 0.5 - centre.y * scale
            if (dx * dx + dy * dy).squareRoot() <= reach { nearCentre += 1 }
        }
    }
    return (columns, x0, count, nearCentre)
}

func runs(of columns: [Bool]) -> [ClosedRange<Int>] {
    var found: [ClosedRange<Int>] = []
    var start: Int?
    for (index, filled) in columns.enumerated() {
        if filled, start == nil { start = index }
        if !filled, let begin = start {
            found.append(begin...(index - 1))
            start = nil
        }
    }
    if let begin = start { found.append(begin...(columns.count - 1)) }
    return found
}

func classify(_ rgba: [UInt8], width: Int, height: Int, scale: Double, centre: CGPoint) -> Seen {
    let seen = opaqueColumns(rgba, width: width, height: height, scale: scale, centre: centre)
    if seen.count == 0 { return .none }
    if seen.nearCentre == 0 { return .spinner }
    let separate = runs(of: seen.columns).count
    if separate >= 4 { return .waveform }
    return separate == 1 ? .arrow : .unknown
}

/// Height in points of the middle bar of a waveform: the opaque rows across its column run.
func middleBarHeight(_ rgba: [UInt8], width: Int, height: Int, scale: Double, centre: CGPoint) -> Double {
    let seen = opaqueColumns(rgba, width: width, height: height, scale: scale, centre: centre)
    let bars = runs(of: seen.columns)
    guard !bars.isEmpty else { return 0 }
    let middle = bars[bars.count / 2]
    var top = Int.max
    var bottom = Int.min
    for y in 0..<height {
        for column in middle where rgba[(y * width + seen.first + column) * 4 + 3] >= 230 {
            top = min(top, y)
            bottom = max(bottom, y)
        }
    }
    return bottom < top ? 0 : Double(bottom - top + 1) / scale
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
            if (3...4).contains(arguments.count), arguments[1] == "--app", let pid = Int32(arguments[2]) {
                await checkApp(pid: pid, restSeconds: arguments.count == 4 ? Double(arguments[3]) : nil)
            } else if arguments.count == 4, arguments[1] == "--looks", let pid = Int32(arguments[2]), let rest = Double(arguments[3]) {
                await checkLooks(pid: pid, restSeconds: rest)
            } else if arguments.count == 3, arguments[1] == "--rearranged", let pid = Int32(arguments[2]) {
                await checkRearranged(pid: pid)
            } else if arguments.count == 3, arguments[1] == "--replug", let pid = Int32(arguments[2]) {
                await checkReplug(pid: pid)
            } else if arguments.count == 3, arguments[1] == "--panel", let pid = Int32(arguments[2]) {
                await checkPanel(pid: pid)
            } else {
                checkPlacement()
                checkLooksRender()
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

    static func capture(_ overlay: Overlay) -> (pixels: Pixels, scale: Double)? {
        let path = NSTemporaryDirectory() + "companion-check-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l\(overlay.number)", path]
        guard (try? capture.run()) != nil else { return nil }
        capture.waitUntilExit()
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pixels = decode(image)
        else { return nil }
        return (pixels, Double(pixels.width) / overlay.bounds.width)
    }

    static func glyph(in overlay: Overlay) -> (centre: CGPoint, count: Int)? {
        guard let (pixels, scale) = capture(overlay) else { return nil }
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.rgba[(y * pixels.width + x) * 4 + 3] >= 230 {
                sumX += Double(x) + 0.5
                sumY += Double(y) + 0.5
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (CGPoint(x: sumX / Double(count) / scale, y: sumY / Double(count) / scale), count)
    }

    static func seen(in overlay: Overlay, centre: CGPoint) -> Seen {
        guard let (pixels, scale) = capture(overlay) else { return .unknown }
        return classify(pixels.rgba, width: pixels.width, height: pixels.height, scale: scale, centre: centre)
    }

    static func near(_ a: CGPoint?, _ b: CGPoint, within tolerance: CGFloat) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func describe(_ point: CGPoint?) -> String {
        point.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "none"
    }

    static func checkApp(pid: Int32, restSeconds: Double?) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        let all = overlays(pid)
        await checkDisplays(pid: pid)

        await checkDrag(overlays: all)
        if let restSeconds { await checkRest(overlays: all, restSeconds: restSeconds, pid: pid) }
        checkFeed(pid: pid)

        move(to: saved)
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func checkDisplays(pid: Int32) async {
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
    }

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func displayBounds() -> [CGRect] {
        activeDisplays().map { CGDisplayBounds($0) }
    }

    static func sorted(_ rects: [CGRect]) -> [CGRect] {
        rects.sorted { ($0.minX, $0.minY, $0.width, $0.height) < ($1.minX, $1.minY, $1.width, $1.height) }
    }

    static func overlaysMatchDisplays(_ pid: Int32, _ label: String) {
        let found = sorted(overlays(pid).map(\.bounds))
        let truth = sorted(displayBounds())
        expect(found == truth, "\(label): each display has exactly one overlay covering it",
               "overlays \(found) vs displays \(truth)")
    }

    static func waitForDisplays(_ until: ([CGRect]) -> Bool, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if until(displayBounds()) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return until(displayBounds())
    }

    // macOS posts further display notices up to about 5 s after a change, and each one replaces
    // every overlay, so a window number read before they stop goes stale.
    static func waitForSettledOverlays(_ pid: Int32) async -> [Overlay] {
        var current = overlays(pid)
        var changed = Date()
        let deadline = Date().addingTimeInterval(30)
        while Date().timeIntervalSince(changed) < 7, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let now = overlays(pid)
            if Set(now.map(\.number)) != Set(current.map(\.number)) {
                current = now
                changed = Date()
            }
        }
        expect(Date().timeIntervalSince(changed) >= 7, "the overlays stopped changing within 30 s")
        return current
    }

    static func expectReplaced(_ before: [Overlay], by after: [Overlay], _ label: String) {
        let old = Set(before.map(\.number)), new = Set(after.map(\.number))
        expect(old.isDisjoint(with: new), label, "windows \(old.sorted()) then \(new.sorted())")
    }

    static func checkRearranged(pid: Int32) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        let main = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(main)
        guard let other = activeDisplays().first(where: { $0 != main }) else {
            print("  info one display, so no rearrangement to check")
            return
        }
        let original = CGDisplayBounds(other)
        let rightOfMain = CGPoint(x: mainBounds.maxX, y: mainBounds.minY)
        let target = original.origin == rightOfMain ? CGPoint(x: mainBounds.minX, y: mainBounds.maxY) : rightOfMain

        let before = overlays(pid)
        var config: CGDisplayConfigRef?
        var result = CGBeginDisplayConfiguration(&config)
        if result == .success {
            result = CGConfigureDisplayOrigin(config, other, Int32(target.x), Int32(target.y))
        }
        if result == .success {
            result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        } else {
            CGCancelDisplayConfiguration(config)
        }
        expect(result == .success, "the display moved to \(describe(target))", "CGError \(result.rawValue)")

        _ = await waitForDisplays({ $0.contains { $0.origin == target } }, seconds: 5)
        let rearranged = await waitForSettledOverlays(pid)
        overlaysMatchDisplays(pid, "after the rearrangement")
        expectReplaced(before, by: rearranged, "the app rebuilt its overlays")
        await checkDisplays(pid: pid)

        CGRestorePermanentDisplayConfiguration()
        _ = await waitForDisplays({ $0.contains { $0 == original } }, seconds: 5)
        _ = await waitForSettledOverlays(pid)
        overlaysMatchDisplays(pid, "after the restore")

        move(to: saved)
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func checkReplug(pid: Int32) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        let count = activeDisplays().count
        let before = overlays(pid)
        print("  info waiting up to 5 minutes for a display to be unplugged")
        let unplugged = await waitForDisplays({ $0.count < count }, seconds: 300)
        expect(unplugged, "a display was unplugged")
        guard unplugged else { return }
        let afterUnplug = await waitForSettledOverlays(pid)
        overlaysMatchDisplays(pid, "after the unplug")
        expectReplaced(before, by: afterUnplug, "the app rebuilt its overlays after the unplug")

        if let remaining = activeDisplays().first, let overlay = overlays(pid).first(where: { $0.bounds == CGDisplayBounds(remaining) }) {
            let b = overlay.bounds
            move(to: CGPoint(x: b.midX, y: b.midY))
            try? await Task.sleep(for: .milliseconds(800))
            let expected = CGPoint(x: b.width / 2 + 35, y: b.height / 2 + 25)
            let found = glyph(in: overlay)?.centre
            expect(near(found, expected, within: 2), "after the unplug the glyph follows on the remaining display",
                   "\(describe(found)) vs \(describe(expected))")
        } else {
            expect(false, "after the unplug the glyph follows on the remaining display", "no overlay on a remaining display")
        }

        print("  info waiting up to 90 s for the display to come back")
        let back = await waitForDisplays({ $0.count == count }, seconds: 90)
        expect(back, "the display came back")
        if back {
            let afterReplug = await waitForSettledOverlays(pid)
            overlaysMatchDisplays(pid, "after the replug")
            expectReplaced(afterUnplug, by: afterReplug, "the app rebuilt its overlays after the replug")
            await checkDisplays(pid: pid)
        }

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

    static func checkRest(overlays all: [Overlay], restSeconds: Double, pid: Int32) async {
        let main = CGMainDisplayID()
        guard let overlay = all.first(where: { $0.bounds == CGDisplayBounds(main) }) else {
            expect(false, "the primary display has an overlay")
            return
        }
        try? await Task.sleep(for: .seconds(restSeconds + 1.5))
        expect(glyph(in: overlay) == nil, "a pointer still past the rest time hides the glyph")
        expect(companionLog(pid: pid).contains("companion resting"), "the app logged companion resting")

        let here = CGEvent(source: nil)?.location ?? .zero
        let target = CGPoint(x: here.x - 40, y: here.y)
        move(to: target)
        try? await Task.sleep(for: .milliseconds(800))
        let local = CGPoint(x: target.x - overlay.bounds.minX + 35, y: target.y - overlay.bounds.minY + 25)
        let found = glyph(in: overlay)?.centre
        expect(near(found, local, within: 2), "a move after the rest brings the glyph back",
               "\(describe(found)) vs \(describe(local))")
    }

    static func companionLog(pid: Int32, categories: [String] = ["companion"]) -> String {
        let match = categories.map { "category == \"\($0)\"" }.joined(separator: " OR ")
        let log = Process()
        log.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        log.arguments = ["show", "--last", "2m", "--style", "syslog", "--predicate",
                         "processIdentifier == \(pid) AND subsystem == \"my.rooftop.sherpa\" AND (\(match))"]
        let pipe = Pipe()
        log.standardOutput = pipe
        log.standardError = FileHandle.nullDevice
        var text = ""
        if (try? log.run()) != nil {
            text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            log.waitUntilExit()
        }
        return text
    }

    @MainActor
    static func render(_ look: CompanionGlyph.Look, time: Double) -> (pixels: Pixels, scale: Double)? {
        let renderer = ImageRenderer(content: CompanionGlyph(look: look, time: time).frame(width: 60, height: 60))
        renderer.scale = 2
        guard let image = renderer.cgImage, let pixels = decode(image) else { return nil }
        return (pixels, 2)
    }

    @MainActor
    static func checkLooksRender() {
        let centre = CGPoint(x: 30, y: 30)
        func seen(_ look: CompanionGlyph.Look, time: Double = 0) -> Seen {
            guard let (pixels, scale) = render(look, time: time) else { return .unknown }
            return classify(pixels.rgba, width: pixels.width, height: pixels.height, scale: scale, centre: centre)
        }
        expect(seen(.arrow) == .arrow, "the idle look is the arrowhead", seen(.arrow).rawValue)
        let quiet = seen(.waveform(level: 0.05))
        let loud = seen(.waveform(level: 1.0))
        expect(quiet == .waveform && loud == .waveform, "the listening look is a waveform", "\(quiet.rawValue), \(loud.rawValue)")
        func barHeight(_ level: Double) -> Double {
            guard let (pixels, scale) = render(.waveform(level: level), time: 0) else { return 0 }
            return middleBarHeight(pixels.rgba, width: pixels.width, height: pixels.height, scale: scale, centre: centre)
        }
        let low = barHeight(0.05)
        let high = barHeight(1.0)
        expect(high - low >= 10, "the waveform rises with the level", String(format: "%.1f pt at 0.05, %.1f pt at 1.0", low, high))
        let first = render(.spinner, time: 0)
        let second = render(.spinner, time: 0.2)
        let spinning = [first, second].map { $0.map { classify($0.pixels.rgba, width: $0.pixels.width, height: $0.pixels.height, scale: $0.scale, centre: centre) } }
        expect(spinning == [.spinner, .spinner] && first?.pixels.rgba != second?.pixels.rgba, "the spinner turns",
               "\(spinning.map { $0?.rawValue ?? "nil" })")
    }

    static func checkLooks(pid: Int32, restSeconds: Double) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        guard let display = NSScreen.screens.map(displayID).first(where: { CGDisplayBounds($0).contains(saved) }),
              let overlay = overlays(pid).first(where: { $0.bounds == CGDisplayBounds(display) })
        else {
            expect(false, "the display holding the pointer has an overlay", "pointer \(describe(saved))")
            return
        }
        let b = overlay.bounds
        let here = CGPoint(x: saved.x - b.minX > 60 ? saved.x - 30 : saved.x + 30, y: saved.y)
        move(to: here)
        try? await Task.sleep(for: .milliseconds(800))
        let centre = CGPoint(
            x: min(max(here.x - b.minX + 35, 12), b.width - 12),
            y: min(max(here.y - b.minY + 25, 12), b.height - 12))

        func sample(upTo seconds: Double, until wanted: Seen) -> Seen {
            let deadline = Date().addingTimeInterval(seconds)
            var last = Seen.unknown
            repeat {
                last = seen(in: overlay, centre: centre)
                if last == wanted { return last }
            } while Date() < deadline
            return last
        }
        func chord(down: Bool) async {
            if down {
                postModifier(59, down: true, flags: .maskControl)
                try? await Task.sleep(for: .milliseconds(100))
                postModifier(58, down: true, flags: [.maskControl, .maskAlternate])
            } else {
                postModifier(58, down: false, flags: .maskControl)
                try? await Task.sleep(for: .milliseconds(100))
                postModifier(59, down: false, flags: [])
            }
        }

        func lastState() -> String? {
            companionLog(pid: pid, categories: ["state"]).split(separator: "\n").last { $0.contains("state voice=") }.map(String.init)
        }
        let idleBy = Date().addingTimeInterval(20)
        var state = lastState()
        while let line = state, !line.contains("voice=idle"), Date() < idleBy {
            try? await Task.sleep(for: .milliseconds(500))
            state = lastState()
        }
        expect(state?.contains("voice=idle") ?? true, "the previous turn has ended in idle", state ?? "no state line in 2 minutes")

        let before = seen(in: overlay, centre: centre)
        expect(before == .arrow, "before the hold the companion is the arrowhead", before.rawValue)

        try? await Task.sleep(for: .seconds(restSeconds + 1.5))
        let resting = seen(in: overlay, centre: centre)
        expect(resting == .none, "a still pointer past the rest time hides it", resting.rawValue)

        var sequence: [Seen] = []
        func note(_ look: Seen) { if look != .unknown, sequence.last != look { sequence.append(look) } }

        let pressed = Date()
        await chord(down: true)
        let held = sample(upTo: 2.5, until: .waveform)
        note(held)
        expect(held == .waveform, "holding the hotkey wakes it as a waveform", held.rawValue)

        let remaining = 2 - Date().timeIntervalSince(pressed)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        await chord(down: false)
        let released = sample(upTo: 1.5, until: .spinner)
        note(released)
        expect(released == .spinner, "after the release it spins", released.rawValue)

        let done = sample(upTo: 20, until: .arrow)
        note(done)
        expect(done == .arrow, "once the voice has the answer it is the arrowhead again", done.rawValue)
        print("  info looks from the press: \(sequence.map(\.rawValue).joined(separator: " -> "))")

        try? await Task.sleep(for: .seconds(1))
        let lines = companionLog(pid: pid, categories: ["companion", "state"])
            .split(separator: "\n").map(String.init)
        let lastRest = lines.lastIndex { $0.contains("companion resting") }
        let woke = lastRest.flatMap { rest in lines[rest...].firstIndex { $0.contains("companion woke") } }
        expect(woke != nil, "the companion logged woke after resting", lines.filter { $0.contains("companion ") }.joined(separator: "\n"))
        let listening = lines.lastIndex { $0.contains("state voice=listening") }
        let responding = listening.flatMap { start in lines[start...].firstIndex { $0.contains("state voice=responding") } }
        expect(responding != nil, "the state went through responding", lines.filter { $0.contains("state voice=") }.joined(separator: "\n"))

        move(to: saved)
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func postModifier(_ virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: virtualKey, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func checkFeed(pid: Int32) {
        let text = companionLog(pid: pid)
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
