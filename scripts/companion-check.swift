import AppKit
import ApplicationServices
import CoreMedia
import ImageIO
import ScreenCaptureKit
import SwiftUI
import Vision

final class RecordingView: NSView {
    var downs = 0
    var ups = 0
    var drags = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
    override func mouseDragged(with event: NSEvent) { drags += 1 }
}

struct Overlay {
    let number: Int
    let bounds: CGRect
}

enum Seen: String { case none, arrow, waveform, spinner, unknown }

nonisolated struct Blob {
    let box: CGRect
    let centre: CGPoint
    let count: Int
}

nonisolated func blobs(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int, row: Int, scale: Double) -> [Blob] {
    var opaque = Set<Int>()
    for y in 0..<height {
        for x in 0..<width where bytes[y * row + x * 4 + 3] >= 230 { opaque.insert(y * width + x) }
    }
    var found: [Blob] = []
    while let seed = opaque.popFirst() {
        var stack = [seed]
        var (minX, minY, maxX, maxY) = (Int.max, Int.max, Int.min, Int.min)
        var (sumX, sumY, count) = (0.0, 0.0, 0)
        while let index = stack.popLast() {
            let (x, y) = (index % width, index / width)
            (minX, minY, maxX, maxY) = (min(minX, x), min(minY, y), max(maxX, x), max(maxY, y))
            sumX += Double(x) + 0.5
            sumY += Double(y) + 0.5
            count += 1
            for dy in -1...1 {
                for dx in -1...1 where (0..<width).contains(x + dx) && (0..<height).contains(y + dy) {
                    if let next = opaque.remove((y + dy) * width + x + dx) { stack.append(next) }
                }
            }
        }
        found.append(Blob(
            box: CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                        width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale),
            centre: CGPoint(x: sumX / Double(count) / scale, y: sumY / Double(count) / scale),
            count: count))
    }
    return found.sorted { $0.count > $1.count }
}

func bubbleZone(_ frame: CGRect, side: String) -> CGRect {
    let overshoot = frame.width * 0.15
    return CGRect(x: frame.minX - 4 - (side == "left" ? overshoot : 0), y: frame.minY - 4,
                  width: frame.width + 8 + overshoot, height: frame.height + 8)
}

func ringZone(_ bounds: CGRect) -> CGRect {
    bounds.insetBy(dx: -24, dy: -24)
}

nonisolated struct Frame {
    let time: Double
    let blobs: [Blob]

    func bubble(in zone: CGRect?) -> Blob? {
        guard let zone else { return nil }
        return blobs.first { zone.contains($0.box) }
    }

    func glyph(besides zones: [CGRect]) -> CGPoint? {
        let parts = blobs.filter { blob in !zones.contains { $0.contains(blob.box) } }
        let count = Double(parts.reduce(0) { $0 + $1.count })
        guard count > 0 else { return nil }
        return CGPoint(x: parts.reduce(0) { $0 + $1.centre.x * Double($1.count) } / count,
                       y: parts.reduce(0) { $0 + $1.centre.y * Double($1.count) } / count)
    }
}

nonisolated final class FrameRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let width: Double
    private let lock = NSLock()
    private var recorded: [Frame] = []

    init(overlayWidth: Double) {
        width = overlayWidth
    }

    var frames: [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func start(window number: Int) async -> SCStream? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { Int($0.windowID) == number })
        else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = false
        configuration.backgroundColor = .clear
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration, delegate: nil)
        guard (try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "companion-check.frames"))) != nil,
              (try? await stream.startCapture()) != nil
        else { return nil }
        return stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sample.imageBuffer
        else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let (w, h, row) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), CVPixelBufferGetBytesPerRow(buffer))
        let found = blobs(base.assumingMemoryBound(to: UInt8.self), width: w, height: h, row: row, scale: Double(w) / width)
        lock.lock()
        recorded.append(Frame(time: CACurrentMediaTime(), blobs: Array(found.prefix(32))))
        lock.unlock()
    }
}

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
            } else if arguments.count == 4, arguments[1] == "--flight", let pid = Int32(arguments[2]) {
                await checkFlight(pid: pid, voiceScenario: arguments[3])
            } else if arguments.count == 6, arguments[1] == "--ink", let pid = Int32(arguments[2]), let stale = Double(arguments[5]) {
                await checkInk(pid: pid, requests: arguments[3], hearing: arguments[4], staleSeconds: stale)
            } else {
                checkPlacement()
                checkLanding()
                checkArc()
                checkBubble()
                await checkPointing()
                await checkMarks()
                checkLooksRender()
                checkBubbleRender()
                checkRingRender()
                checkMarkRender()
                checkInkRender()
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

    static func checkLanding() {
        let one = [CGRect(x: 0, y: 0, width: 1710, height: 1112)]
        let two = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 97, y: -1112, width: 1710, height: 1112)]
        func callout(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> Callout {
            Callout(point: CGPoint(x: x + width / 2, y: y + height / 2), label: "a", bounds: CGRect(x: x, y: y, width: width, height: height))
        }
        let rows: [(String, Callout, [CGRect], CGPoint)] = [
            ("a callout without bounds lands where following its point would", Callout(point: CGPoint(x: 600, y: 400), label: "a", bounds: nil), one,
             CGPoint(x: 635, y: 375)),
            ("bounds land 35 right of and 25 below their bottom-right corner", callout(500, 380, 100, 40), one, CGPoint(x: 635, y: 355)),
            ("bounds too thin for a ring still land beside their corner", callout(600, 400, 2, 30), one, CGPoint(x: 637, y: 375)),
            ("bounds on a screen's right edge clamp inside it", callout(1650, 500, 60, 30), one, CGPoint(x: 1698, y: 475)),
            ("bounds on the bottom edge of the upper display clamp inside it, not onto the display below", callout(800, 0, 100, 30), two,
             CGPoint(x: 935, y: 12)),
        ]
        for (label, callout, screens, expected) in rows {
            let actual = Companion.landing(for: callout, on: screens)
            expect(actual == expected, label, "\(actual) vs \(expected)")
        }
    }

    static func exact(_ point: CGPoint) -> String {
        String(format: "(%.5f, %.5f)", point.x, point.y)
    }

    static func checkArc() {
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 0.001 && abs(a.y - b.y) <= 0.001 }
        func degrees(_ angle: Angle) -> String { String(format: "%.5f degrees", angle.degrees) }
        func seconds(_ duration: Duration) -> Double { duration / .seconds(1) }

        let across = Flight(from: .zero, to: CGPoint(x: 1000, y: 0))
        expect(close(across.control, CGPoint(x: 500, y: 80)), "a 1000 pt flight bows toward a point 80 pt above its midpoint",
               exact(across.control))
        expect(abs(seconds(across.duration) - 0.6667) <= 0.001, "a 1000 pt flight takes 0.6667 s", "\(across.duration)")
        let rows: [(Double, CGPoint)] = [
            (0, CGPoint(x: 0, y: 0)),
            (0.25, CGPoint(x: 156.25, y: 21.09375)),
            (0.5, CGPoint(x: 500, y: 40)),
            (1, CGPoint(x: 1000, y: 0)),
        ]
        for (progress, expected) in rows {
            let actual = across.position(after: across.duration * progress)
            expect(close(actual, expected), "\(progress) of the way through, the 1000 pt flight is at \(exact(expected))", exact(actual))
        }
        expect(abs(across.heading(after: across.duration / 2).degrees - 90) <= 0.001, "halfway through a flight to the right the apex faces right",
               degrees(across.heading(after: across.duration / 2)))
        expect(abs(across.heading(after: .zero).radians - atan2(1000, 160)) <= 0.001, "at takeoff the apex faces up the curve, toward the bow",
               degrees(across.heading(after: .zero)))

        let far = Flight(from: .zero, to: CGPoint(x: 3000, y: 0))
        expect(abs(far.control.y - 80) <= 0.001 && abs(seconds(far.duration) - 1.2) <= 0.001,
               "a 3000 pt flight still rises at most 80 pt and takes at most 1.2 s", "\(exact(far.control)), \(far.duration)")
        let near = Flight(from: .zero, to: CGPoint(x: 100, y: 0))
        expect(abs(near.control.y - 20) <= 0.001 && abs(seconds(near.duration) - 0.5) <= 0.001,
               "a 100 pt flight rises 20 pt and takes at least 0.5 s", "\(exact(near.control)), \(near.duration)")
        let down = Flight(from: .zero, to: CGPoint(x: 0, y: -600))
        expect(abs(down.heading(after: down.duration / 2).degrees - 180) <= 0.001, "halfway through a downward flight the apex faces down",
               degrees(down.heading(after: down.duration / 2)))
    }

    static func checkBubble() {
        let screen = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        let reveals = (0...5).map { Bubble.reveal($0) / .milliseconds(1) }
        expect(reveals == [0, 30, 77, 110, 160, 196], "characters show at 0, 30, 77, 110, 160 and 196 ms", "\(reveals)")
        let bubble = Bubble(label: "panel", beside: CGPoint(x: 600, y: 400), on: screen, appeared: .now)
        let shown = [0, 29, 30, 76, 77, 160, 5000].map { bubble.revealed(after: .milliseconds($0)) }
        expect(shown == [1, 1, 2, 2, 3, 5, 5], "0, 29, 30, 76, 77, 160 and 5000 ms in, 1, 1, 2, 2, 3, 5 and 5 characters of five show",
               "\(shown)")
        expect(bubble.typing == .milliseconds(160), "a five-character label is typed 160 ms after the bubble appears", "\(bubble.typing)")
        expect(bubble.side == .right && bubble.frame.minX == 610 && bubble.frame.midY == 382,
               "mid-screen the bubble starts 10 pt right of the glyph, its middle 18 pt below", "\(bubble.side) \(bubble.frame)")
        let edge = Bubble(label: "panel", beside: CGPoint(x: 1900, y: 500), on: screen, appeared: .now)
        expect(edge.side == .left && edge.frame.maxX == 1890 && screen[0].contains(edge.frame),
               "near the right edge it flips left, ending 10 pt left of the glyph, inside the screen", "\(edge.side) \(edge.frame)")
        let low = Bubble(label: "panel", beside: CGPoint(x: 600, y: 15), on: screen, appeared: .now)
        expect(low.side == .right && low.frame.minY == 12, "near the bottom edge it clamps up to 12 pt inside", "\(low.side) \(low.frame)")
        let long = Bubble(label: String(repeating: "a long label ", count: 10), beside: CGPoint(x: 600, y: 400), on: screen, appeared: .now)
        expect(long.frame.width == 240, "a long label is cut to a 240 pt bubble", "\(long.frame)")
    }

    static func checkPointing() async {
        guard let frame = NSScreen.screens.first?.frame else {
            expect(false, "a screen to point on")
            return
        }
        let companion = Companion(hold: .milliseconds(300))
        func spot(_ target: CGPoint) -> CGPoint { CGPoint(x: target.x + 35, y: target.y - 25) }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        func wait(until deadline: ContinuousClock.Instant) async { try? await Task.sleep(until: deadline, clock: .continuous) }
        func wait(upTo limit: Duration, for done: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            return done()
        }
        func offCurve(_ point: CGPoint, _ flight: Flight) -> CGFloat {
            (0..<1000).map { distance(point, flight.position(after: flight.duration * (Double($0) / 999))) }.min() ?? .infinity
        }
        func restingTurns() -> Double {
            (companion.heading.radians - Companion.restingHeading.radians) / (2 * .pi)
        }
        func faces() -> Bool { abs(restingTurns() - restingTurns().rounded()) * 2 * .pi <= 0.001 }
        nonisolated final class Latch: @unchecked Sendable { var pointer: CGPoint? }
        func pointerAtNextChange() -> Latch {
            let latch = Latch()
            withObservationTracking { _ = companion.bubble } onChange: { latch.pointer = MainActor.assumeIsolated { NSEvent.mouseLocation } }
            return latch
        }
        func following(_ latch: Latch) -> CGPoint {
            Companion.position(following: latch.pointer ?? NSEvent.mouseLocation, on: NSScreen.screens.map(\.frame))
        }

        let home = companion.position
        let left = CGPoint(x: frame.minX + 300, y: frame.midY)
        let right = CGPoint(x: frame.maxX - 300, y: frame.midY)
        let target = distance(home, left) > distance(home, right) ? left : right
        let callout = Callout(point: target, label: "panel", bounds: nil)
        let destination = spot(target)
        let outbound = Flight(from: home, to: destination)
        let started = ContinuousClock.now
        companion.point(at: callout)
        await wait(until: started + .milliseconds(200))
        let mid = companion.position
        let along = (mid.x - home.x) / (destination.x - home.x)
        let rise = mid.y - (home.y + along * (destination.y - home.y))
        expect(along > 0 && along < 1 && rise > 5, "0.2 s after pointing the glyph is partway there, above the straight line",
               "\(describe(mid)) from \(describe(home)) to \(describe(destination))")
        companion.followPointer()
        expect(distance(companion.position, mid) <= 0.001, "on the way out a mouse event leaves the glyph on its arc",
               "\(exact(companion.position)) vs \(exact(mid))")
        companion.point(at: callout)
        await wait(until: started + outbound.duration + .milliseconds(150))
        let landed = companion.bubble
        expect(distance(companion.position, destination) <= 0.001 && faces(),
               "pointing again at the same callout does not restart the flight, which lands on time facing the target",
               "\(exact(companion.position)) vs \(exact(destination)), heading \(companion.heading.degrees)")
        expect(landed?.label == "panel" && landed?.side == .right && landed?.frame.minX == destination.x + 10,
               "on landing the bubble shows the label 10 pt right of the glyph", "\(String(describing: landed))")

        let release = pointerAtNextChange()
        companion.point(at: nil)
        await wait(until: started + outbound.duration + .milliseconds(400))
        companion.followPointer()
        expect(distance(companion.position, destination) <= 0.001 && companion.bubble != nil,
               "a voice that stops before typing plus the hold leaves the glyph and bubble beside the target, whatever the mouse does",
               "\(exact(companion.position)), bubble \(companion.bubble != nil)")
        let released = await wait(upTo: .seconds(1)) { companion.bubble == nil }
        let releasedAt = ContinuousClock.now
        let typedAndHeld = started + outbound.duration + .milliseconds(160 + 300)
        expect(released && releasedAt >= typedAndHeld && releasedAt < typedAndHeld + .milliseconds(100),
               "the bubble goes 160 ms of typing plus the 300 ms hold after landing",
               "\(released ? "\((releasedAt - typedAndHeld) / .milliseconds(1)) ms after that" : "still up")")
        let back = Flight(from: destination, to: following(release))
        let arrival = pointerAtNextChange()
        await wait(until: releasedAt + .milliseconds(100))
        let homeward = companion.position
        expect(offCurve(homeward, back) <= 0.5 && distance(homeward, destination) > 5 && distance(homeward, back.to) > 5,
               "then the glyph flies home along an arc from the spot to where following puts the pointer",
               String(format: "%.2f pt off the arc at %@", offCurve(homeward, back), describe(homeward)))
        let drift = distance(NSEvent.mouseLocation, release.pointer ?? .zero)
        if drift < 20 {
            companion.followPointer()
            expect(distance(companion.position, homeward) <= 0.001, "a mouse event inside the dead zone leaves the flight home going",
                   "\(exact(companion.position)) vs \(exact(homeward))")
        } else {
            print(String(format: "  info the mouse moved %.0f pt during the flight home, so the dead-zone check did not run", drift))
        }
        let arrived = await wait(upTo: back.duration + .milliseconds(500)) { arrival.pointer != nil }
        expect(arrived && distance(companion.position, following(arrival)) <= 0.001 && faces(),
               "and lands home, following the pointer and facing it", "\(exact(companion.position)) vs \(exact(following(arrival)))")

        let topLeft = CGPoint(x: frame.minX + 300, y: frame.maxY - 200)
        let topRight = CGPoint(x: frame.maxX - 300, y: frame.maxY - 200)
        let second = ContinuousClock.now
        let early = Flight(from: companion.position, to: spot(topLeft))
        companion.point(at: Callout(point: topLeft, label: "Wi-Fi", bounds: nil))
        await wait(until: second + .milliseconds(200))
        companion.point(at: nil)
        await wait(until: second + early.duration + .milliseconds(150))
        expect(distance(companion.position, spot(topLeft)) <= 0.001 && companion.bubble?.label == "Wi-Fi",
               "a voice that stops mid-flight still lands with the bubble up", "\(exact(companion.position)), \(String(describing: companion.bubble))")
        let returning = await wait(upTo: .seconds(1)) { companion.bubble == nil }
        await wait(until: .now + .milliseconds(100))
        let turned = companion.position
        let retargeted = ContinuousClock.now
        companion.point(at: Callout(point: topRight, label: "switch", bounds: nil))
        await wait(until: retargeted + .milliseconds(30))
        expect(returning && distance(turned, spot(topLeft)) > 5 && distance(companion.position, turned) < 10,
               "a new callout on the way home takes off from where the glyph is",
               "\(exact(companion.position)) vs \(exact(turned)), \(returning ? "returning" : "never left")")
        let across = Flight(from: turned, to: spot(topRight))
        await wait(until: retargeted + across.duration + .milliseconds(150))
        expect(distance(companion.position, spot(topRight)) <= 0.001 && faces() && companion.bubble?.label == "switch",
               "and lands on the new spot with the new label", "\(exact(companion.position)) vs \(exact(spot(topRight)))")
        await wait(until: retargeted + across.duration + .milliseconds(1000))
        expect(distance(companion.position, spot(topRight)) <= 0.001 && companion.bubble?.label == "switch",
               "while the voice still speaks the glyph stays past typing plus the hold", exact(companion.position))

        let bottomRight = CGPoint(x: frame.maxX - 200, y: frame.minY + 200)
        let fourth = ContinuousClock.now
        let steep = Flight(from: companion.position, to: spot(bottomRight))
        companion.point(at: Callout(point: bottomRight, label: "panel", bounds: nil))
        expect(companion.bubble == nil, "a new callout while the glyph pauses takes the bubble down")
        await wait(until: fourth + .milliseconds(30))
        expect(distance(companion.position, spot(topRight)) < 10, "and takes off from the spot",
               "\(exact(companion.position)) vs \(exact(spot(topRight)))")
        await wait(until: fourth + steep.duration + .milliseconds(150))
        let landing = steep.heading(after: steep.duration).radians
        expect(distance(companion.position, spot(bottomRight)) <= 0.001 && faces() && abs(companion.heading.radians - landing) <= .pi,
               "it flies there, and on landing the arrow turns the shorter way to face the target",
               String(format: "heading %.1f degrees after a flight that ends at %.1f", companion.heading.degrees, landing * 180 / .pi))
        companion.point(at: nil)
        let gone = await wait(upTo: .seconds(1)) { companion.bubble == nil }
        let last = pointerAtNextChange()
        let home2 = await wait(upTo: .seconds(2)) { last.pointer != nil }
        expect(gone && home2 && distance(companion.position, following(last)) <= 0.001,
               "once the voice stops and the hold runs out it flies home and follows the pointer",
               "\(exact(companion.position)) vs \(exact(following(last)))")

        try? await Task.sleep(for: .seconds(1))
        let logged = companionLog(pid: ProcessInfo.processInfo.processIdentifier).split(separator: "\n").compactMap { line in
            ["flying", "landed", "pausing", "returning", "cancelled", "following"].first { line.contains("companion \($0)") }
        }
        let expected = ["flying", "landed", "pausing", "returning", "landed", "following",
                        "flying", "landed", "pausing", "returning", "flying", "landed", "pausing",
                        "flying", "landed", "pausing", "returning", "landed", "following"]
        expect(logged == expected, "the log reads each flight out, its landing and pause, and each flight home landing before following",
               logged.joined(separator: ", "))
    }

    static func checkMarks() async {
        guard let frame = NSScreen.screens.first?.frame, frame.width >= 800, frame.height >= 500 else {
            expect(false, "a primary screen of at least 800x500 to mark on", "\(String(describing: NSScreen.screens.first?.frame))")
            return
        }
        let companion = Companion(hold: .milliseconds(300))
        func wait(upTo limit: Duration, for done: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            return done()
        }
        func pause(at callout: Callout) async -> Bool {
            companion.point(at: callout)
            return await wait(upTo: .seconds(2)) { companion.bubble?.label == callout.label }
        }
        func paused(_ landed: Bool) -> String { "\(landed ? "landed" : "never landed") at \(exact(companion.position)), mark \(String(describing: companion.mark))" }

        let panel = Callout(point: CGPoint(x: 440, y: 320), label: "panel", bounds: CGRect(x: 400, y: 300, width: 80, height: 40))
        companion.point(at: panel)
        expect(companion.mark == nil, "on the way out there is no mark yet")
        var landed = await wait(upTo: .seconds(2)) { companion.bubble?.label == "panel" }
        expect(landed && companion.position == CGPoint(x: 515, y: 275) && companion.mark == .ring(CGRect(x: 400, y: 300, width: 80, height: 40)),
               "a callout with bounds lands beside their bottom-right corner and rings exactly those bounds while it pauses", paused(landed))

        let pointed = Callout(point: CGPoint(x: 300, y: 450), label: "Wi-Fi", bounds: nil)
        companion.point(at: pointed)
        expect(companion.mark == nil && companion.bubble == nil, "a new callout takes the mark down with the bubble")
        landed = await wait(upTo: .seconds(2)) { companion.bubble?.label == "Wi-Fi" }
        expect(landed && companion.position == CGPoint(x: 335, y: 425) && companion.mark == nil,
               "a callout without bounds lands where following its point would, and pauses with no ring", paused(landed))

        landed = await pause(at: Callout(point: CGPoint(x: 601.5, y: 470), label: "line", bounds: CGRect(x: 600, y: 450, width: 3, height: 40)))
        expect(landed && companion.position == CGPoint(x: 638, y: 425) && companion.mark == nil,
               "bounds under 4 pt across get no ring, though the glyph still lands beside their corner", paused(landed))

        landed = await pause(at: Callout(point: CGPoint(x: 260, y: 209), label: "Save", bounds: CGRect(x: 200, y: 200, width: 120, height: 18), mark: .underline))
        expect(landed && companion.position == CGPoint(x: 355, y: 175) && companion.mark == .underline(CGRect(x: 200, y: 200, width: 120, height: 18)),
               "an underline callout lands beside the corner of its bounds and underlines exactly those bounds", paused(landed))

        landed = await pause(at: Callout(point: CGPoint(x: 545, y: 151), label: "rule", bounds: CGRect(x: 500, y: 150, width: 90, height: 2), mark: .underline))
        expect(landed && companion.position == CGPoint(x: 625, y: 125) && companion.mark == nil,
               "bounds under 4 pt across get no underline either", paused(landed))

        landed = await pause(at: Callout(point: CGPoint(x: 470, y: 392), label: "Send", bounds: CGRect(x: 420, y: 380, width: 100, height: 24),
                                         mark: .arrow(from: CGRect(x: 100, y: 500, width: 60, height: 30))))
        expect(landed && companion.position == CGPoint(x: 555, y: 355)
                   && companion.mark == .arrow(from: CGRect(x: 100, y: 500, width: 60, height: 30), to: CGRect(x: 420, y: 380, width: 100, height: 24)),
               "an arrow callout lands beside the corner of its bounds and draws an arrow from its start to those bounds", paused(landed))

        landed = await pause(at: Callout(point: CGPoint(x: 700, y: 260), label: "dot", bounds: nil, mark: .arrow(from: CGRect(x: 150, y: 120, width: 40, height: 20))))
        expect(landed && companion.position == CGPoint(x: 735, y: 235)
                   && companion.mark == .arrow(from: CGRect(x: 150, y: 120, width: 40, height: 20), to: CGRect(x: 700, y: 260, width: 0, height: 0)),
               "an arrow to a single pixel draws to a zero-size box on that point", paused(landed))

        companion.point(at: nil)
        let gone = await wait(upTo: .seconds(1)) { companion.bubble == nil }
        expect(gone && companion.mark == nil, "when the pause ends there is no mark")

        try? await Task.sleep(for: .seconds(1))
        let marks = companionLog(pid: ProcessInfo.processInfo.processIdentifier).split(separator: "\n")
            .filter { $0.contains("companion pausing ") }.suffix(7).map { loggedField("mark", in: String($0)).map(String.init) ?? "missing" }
        expect(marks == ["ring:400.0,300.0,80.0,40.0", "none", "none", "underline:200.0,200.0,120.0,18.0", "none",
                         "arrow:100.0,500.0,60.0,30.0->420.0,380.0,100.0,24.0", "arrow:150.0,120.0,40.0,20.0->700.0,260.0,0.0,0.0"],
               "the seven pauses log their marks in order, none for each pause without one", "\(marks)")
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

    static func capturedImage(_ overlay: Overlay) -> CGImage? {
        let path = NSTemporaryDirectory() + "companion-check-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l\(overlay.number)", path]
        guard (try? capture.run()) != nil else { return nil }
        capture.waitUntilExit()
        // ImageIO decodes lazily, so the image must not depend on the file the defer deletes.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func capture(_ overlay: Overlay) -> (pixels: Pixels, scale: Double)? {
        guard let image = capturedImage(overlay), let pixels = decode(image) else { return nil }
        return (pixels, Double(pixels.width) / overlay.bounds.width)
    }

    static func text(in rect: CGRect, of overlay: Overlay) -> String {
        guard let image = capturedImage(overlay) else { return "" }
        let scale = Double(image.width) / overlay.bounds.width
        guard let crop = image.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)),
              let large = CGContext(data: nil, width: Int(rect.width * 4), height: Int(rect.height * 4), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return "" }
        large.interpolationQuality = .high
        large.draw(crop, in: CGRect(x: 0, y: 0, width: large.width, height: large.height))
        guard let enlarged = large.makeImage() else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: enlarged).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
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
        let idle = seen(.arrow(heading: Companion.restingHeading))
        expect(idle == .arrow, "the idle look is the arrowhead", idle.rawValue)
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

    @MainActor
    static func rendered(_ view: some View, scale: Double) -> (pixels: Pixels, blobs: [Blob])? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage, let pixels = decode(image) else { return nil }
        let found = pixels.rgba.withUnsafeBufferPointer {
            blobs($0.baseAddress!, width: pixels.width, height: pixels.height, row: pixels.width * 4, scale: scale)
        }
        return (pixels, found)
    }

    @MainActor
    static func checkInkRender() {
        let screen = CGRect(x: -200, y: 300, width: 200, height: 100)
        func drawn(_ ink: Ink) -> (pixels: Pixels, blobs: [Blob]) {
            rendered(InkLayer(ink: ink, screenFrame: screen).frame(width: screen.width, height: screen.height), scale: 2)
                ?? (Pixels(rgba: [], width: 0, height: 0), [])
        }
        func rgba(_ pixels: Pixels, _ x: Int, _ y: Int) -> [Int] {
            let offset = (y * pixels.width + x) * 4
            return pixels.rgba.count > offset + 3 ? pixels.rgba[offset...(offset + 3)].map(Int.init) : []
        }
        let line = drawn(Ink([Stroke(CGPoint(x: -180, y: 380), [CGPoint(x: -120, y: 380)])]))
        let box = line.blobs.first?.box ?? .zero
        expect(line.blobs.count == 1, "a stroke renders as one blob", "\(line.blobs.count) blobs")
        expect(abs(box.minX - 18) <= 1 && abs(box.width - 64) <= 1 && box.minY == 18 && box.height == 4,
               "a stroke from -180,380 to -120,380 fills 18,18 64x4 on the overlay at -200,300", "\(box)")
        let colour = rgba(line.pixels, 100, 40)
        expect(colour.count == 4 && zip(colour, [255, 48, 43, 255]).allSatisfy { abs($0 - $1) <= 2 },
               "its middle pixel is the ink red 255,48,43", "\(colour)")
        let dot = drawn(Ink([Stroke(CGPoint(x: -100, y: 350))])).blobs
        let disk = dot.first?.box ?? .zero
        expect(dot.count == 1 && near(dot.first?.centre, CGPoint(x: 100, y: 50), within: 0.5) && abs(disk.width - 8) <= 1 && abs(disk.height - 8) <= 1,
               "a one-point stroke at -100,350 is an 8 pt disk centred on 100,50", "\(dot.map { "\($0.box) centre \(describe($0.centre))" })")
        let away = drawn(Ink([Stroke(CGPoint(x: 500, y: 350), [CGPoint(x: 600, y: 350)])]))
        let opaque = stride(from: 3, to: away.pixels.rgba.count, by: 4).filter { away.pixels.rgba[$0] > 0 }.count
        expect(away.pixels.width == 400 && opaque == 0, "a stroke on another screen draws nothing here", "\(opaque) pixels with alpha")
    }

    @MainActor
    static func checkBubbleRender() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = Bubble(label: "Wi-Fi switch", beside: CGPoint(x: 600, y: 400), on: [screen], appeared: .now)
        let left = Bubble(label: "Wi-Fi switch", beside: CGPoint(x: 1900, y: 400), on: [screen], appeared: .now)
        func drawn(_ bubble: Bubble, _ shown: Int) -> (box: CGRect, white: Int) {
            guard let (pixels, found) = rendered(CompanionBubble(bubble: bubble, shown: shown), scale: 2) else { return (.zero, 0) }
            let white = stride(from: 0, to: pixels.rgba.count, by: 4).filter { pixels.rgba[$0] >= 200 && pixels.rgba[$0 + 3] >= 230 }.count
            return (found.first?.box ?? .zero, white)
        }
        let two = drawn(right, 2)
        let all = drawn(right, right.label.count)
        expect(two.white > 0 && two.white < all.white, "two typed characters draw fewer white text pixels than the whole label",
               "\(two.white) vs \(all.white)")
        expect(abs(all.box.width - right.frame.width) <= 1 && abs(all.box.height - right.frame.height) <= 1,
               "typed out, the bubble fills the frame Bubble measured for it", "\(all.box.size) vs \(right.frame.size)")
        expect(two.box.minX <= 0.5 && two.box.width < all.box.width - 10, "while typing it grows away from a glyph on its left",
               "\(two.box) then \(all.box)")
        let leftTwo = drawn(left, 2)
        expect(left.side == .left && abs(leftTwo.box.maxX - left.frame.width) <= 0.5, "and away from a glyph on its right",
               "\(leftTwo.box) in \(left.frame.size)")

        let overlay = CGRect(x: 0, y: 0, width: 400, height: 300)
        let spot = CGPoint(x: 150, y: 200)
        let landed = Bubble(label: "panel", beside: spot, on: [overlay], appeared: .now)
        let zone = bubbleZone(CGRect(origin: Companion.local(CGPoint(x: landed.frame.minX, y: landed.frame.maxY), in: overlay),
                                     size: landed.frame.size), side: landed.side.rawValue)
        let scene = ZStack {
            CompanionGlyph(look: .arrow(heading: Companion.restingHeading), time: 0)
                .position(Companion.local(spot, in: overlay))
            CompanionBubble(bubble: landed, shown: landed.label.count)
                .position(Companion.local(CGPoint(x: landed.frame.midX, y: landed.frame.midY), in: overlay))
        }
        .frame(width: overlay.width, height: overlay.height)
        let sampled = Frame(time: 0, blobs: rendered(scene, scale: 1)?.blobs ?? [])
        let glyph = sampled.glyph(besides: [zone])
        expect(sampled.bubble(in: zone) != nil && near(glyph, Companion.local(spot, in: overlay), within: 1),
               "at the stream's scale the glyph and the bubble beside it read as separate blobs",
               "\(sampled.blobs.map { "\($0.box) x\($0.count)" }), glyph \(describe(glyph))")
    }

    @MainActor
    static func checkRingRender() {
        let around = CGRect(x: 40, y: 30, width: 100, height: 50)
        func drawn(_ fraction: Double) -> (pixels: Pixels, blobs: [Blob]) {
            rendered(CompanionMark(shape: .ring(around), drawn: fraction).frame(width: 200, height: 120), scale: 2)
                ?? (Pixels(rgba: [], width: 0, height: 0), [])
        }
        func rgba(_ pixels: Pixels, _ x: Int, _ y: Int) -> [Int] {
            let offset = (y * pixels.width + x) * 4
            return pixels.rgba.count > offset + 3 ? pixels.rgba[offset...(offset + 3)].map(Int.init) : []
        }
        let full = drawn(1)
        let loop = full.blobs.first?.box ?? .zero
        let whole = full.blobs.reduce(0) { $0 + $1.count }
        expect((full.blobs.first?.count ?? 0) * 100 >= whole * 99,
               "the ring around 40,30 100x50 is one connected loop, bar the faint tip of its tail", "\(full.blobs.map { "\($0.box) x\($0.count)" })")
        expect(loop.minX <= 39 && loop.minY <= 29 && loop.maxX >= 141 && loop.maxY >= 81,
               "the loop surrounds 40,30 100x50 with at least 1 pt clear on every side", "\(loop)")
        expect(ringZone(around).contains(loop), "and lies within 24 pt of it", "\(loop) vs \(ringZone(around))")
        let above = (0..<60).map { rgba(full.pixels, 180, $0) }
        expect(above.contains { $0.count == 4 && zip($0, [51, 122, 255, 255]).allSatisfy { abs($0 - $1) <= 2 } },
               "the line above the box's middle has a pixel of the companion blue 51,122,255", "\(above.filter { $0.last == 255 }.prefix(3))")
        let inside = rgba(full.pixels, 180, 110)
        expect(inside.last == 0, "the box's centre is clear", "\(inside)")
        let half = drawn(0.5).blobs.reduce(0) { $0 + $1.count }
        expect(half * 10 >= whole * 3 && half * 10 <= whole * 7, "drawn to 0.5 it shows 30% to 70% of the loop's pixels", "\(half) of \(whole) pixels")
        _ = drawn(1)
        let start = drawn(0).blobs.reduce(0) { $0 + $1.count }
        expect(start * 100 <= whole, "a new ring starts as a dot of at most 1% of the pixels, even right after a whole ring was drawn", "\(start) of \(whole) pixels")
        expect(drawn(1).pixels.rgba == full.pixels.rgba, "rendering the same ring twice gives identical pixels")

        func inked(around box: CGRect) -> [Bool] {
            guard let scene = rendered(CompanionMark(shape: .ring(box), drawn: 1).frame(width: 300, height: 120), scale: 2)?.pixels else { return [] }
            return stride(from: 3, to: scene.rgba.count, by: 4).map { scene.rgba[$0] >= 128 }
        }
        let here = inked(around: around), there = inked(around: around.offsetBy(dx: 100, dy: 0))
        let (width, shift) = (600, 200)
        let differing = (0..<(here.count / width)).reduce(0) { total, y in
            total + (0..<(width - shift)).filter { here[y * width + $0] != there[y * width + $0 + shift] }.count
        }
        expect(!here.isEmpty && differing >= 40, "two boxes of the same size at different places draw loops that differ once translated",
               "\(differing) differing pixels of \(whole)")

        let overlay = CGRect(x: 0, y: 0, width: 400, height: 300)
        let bounds = CGRect(x: 100, y: 180, width: 80, height: 40)
        let spot = Companion.landing(for: Callout(point: CGPoint(x: bounds.midX, y: bounds.midY), label: "panel", bounds: bounds), on: [overlay])
        let landed = Bubble(label: "panel", beside: spot, on: [overlay], appeared: .now)
        let zone = bubbleZone(Companion.local(landed.frame, in: overlay), side: landed.side.rawValue)
        let ring = Companion.local(bounds, in: overlay)
        let scene = ZStack {
            CompanionMark(shape: .ring(ring), drawn: 1)
            CompanionGlyph(look: .arrow(heading: Companion.restingHeading), time: 0)
                .position(Companion.local(spot, in: overlay))
            CompanionBubble(bubble: landed, shown: landed.label.count)
                .position(Companion.local(CGPoint(x: landed.frame.midX, y: landed.frame.midY), in: overlay))
        }
        .frame(width: overlay.width, height: overlay.height)
        let sampled = Frame(time: 0, blobs: rendered(scene, scale: 1)?.blobs ?? [])
        let glyph = sampled.glyph(besides: [zone, ringZone(ring)])
        expect(sampled.blobs.contains { ringZone(ring).contains($0.box) } && sampled.bubble(in: zone) != nil
                   && near(glyph, Companion.local(spot, in: overlay), within: 1),
               "at the stream's scale the ring, the glyph beside its corner and the bubble read as separate blobs",
               "\(sampled.blobs.map { "\($0.box) x\($0.count)" }), glyph \(describe(glyph))")
    }

    /// Points (in pt) whose alpha is at least half, from a scale-2 render.
    @MainActor
    static func ink(of shape: HandMark.Shape, drawn: Double, size: CGSize) -> [CGPoint] {
        guard let pixels = rendered(CompanionMark(shape: shape, drawn: drawn).frame(width: size.width, height: size.height), scale: 2)?.pixels else { return [] }
        return pixels.rgba.indices.filter { $0 % 4 == 3 && pixels.rgba[$0] >= 128 }.map { i in
            CGPoint(x: Double((i / 4) % pixels.width) / 2, y: Double((i / 4) / pixels.width) / 2)
        }
    }

    static func gap(from point: CGPoint, to box: CGRect) -> Double {
        hypot(max(box.minX - point.x, 0, point.x - box.maxX), max(box.minY - point.y, 0, point.y - box.maxY))
    }

    @MainActor
    static func checkMarkRender() {
        func bounds(_ points: [CGPoint]) -> CGRect {
            guard let first = points.first else { return .null }
            return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        for width in [30.0, 120.0, 260.0] {
            let box = CGRect(x: 40, y: 30, width: width, height: 16)
            let shape = HandMark.Shape.underline(box)
            let size = CGSize(width: width + 100, height: 90)
            let full = ink(of: shape, drawn: 1, size: size)
            let all = bounds(full)
            expect(!full.isEmpty && all.minY >= box.maxY + 1 && all.minY <= box.maxY + 10 && all.maxY <= box.maxY + 12,
                   "the underline of 40,30 \(Int(width))x16 starts 1 to 10 pt under the box's bottom edge and stays within 12 pt", "\(all)")
            expect(all.minX <= box.minX && all.maxX >= box.maxX && all.minX >= box.minX - 9 && all.maxX <= box.maxX + 12,
                   "and spans the box's width, running up to 9 pt past the left and 12 past the right", "\(all)")
            expect(!full.contains { box.contains($0) }, "and has no ink inside the box")
            let half = bounds(ink(of: shape, drawn: 0.5, size: size))
            expect(half.minX <= box.minX && half.maxX >= box.minX + width * 0.2 && half.maxX <= box.maxX - width * 0.15,
                   "drawn to 0.5 it covers the left part of the box and stops short of its right end", "\(half) of \(all)")
            let start = bounds(ink(of: shape, drawn: 0, size: size))
            expect(!start.isNull && start.width <= 6 && start.height <= 6, "a new underline starts as a dot at most 6 pt across", "\(start)")
            expect(ink(of: shape, drawn: 1, size: size) == full, "rendering the same underline twice gives identical pixels")
        }

        let target = CGRect(x: 200, y: 90, width: 60, height: 30)
        let source = CGRect(x: 30, y: 40, width: 40, height: 30)
        let arrows: [(name: String, from: CGRect, to: CGRect)] = [
            ("rightward", source, target),
            ("leftward", target, source),
            ("downward", CGRect(x: 100, y: 10, width: 40, height: 30), CGRect(x: 110, y: 160, width: 50, height: 30)),
            ("upward", CGRect(x: 110, y: 160, width: 50, height: 30), CGRect(x: 100, y: 10, width: 40, height: 30)),
            ("short", CGRect(x: 30, y: 60, width: 40, height: 20), CGRect(x: 110, y: 60, width: 40, height: 20)),
            ("single-pixel", source, CGRect(x: 200, y: 100, width: 0, height: 0)),
        ]
        for (name, from, to) in arrows {
            let shape = HandMark.Shape.arrow(from: from, to: to)
            let size = CGSize(width: 300, height: 220)
            let full = ink(of: shape, drawn: 1, size: size)
            let half = ink(of: shape, drawn: 0.5, size: size)
            expect(!full.isEmpty && !full.contains { from.contains($0) || to.contains($0) }, "the \(name) arrow has no ink inside either box")
            expect(full.contains { gap(from: $0, to: from) <= 12 } && full.contains { gap(from: $0, to: to) <= 12 },
                   "and has ink within 12 pt of each box", "\(bounds(full))")
            let head = full.filter { gap(from: $0, to: to) <= 12 }
            expect(head.count >= 30, "and its head puts at least 30 half-points of ink within 12 pt of the box it points at", "\(head.count)")
            expect(!half.isEmpty && !half.contains { gap(from: $0, to: to) <= 10 } && half.contains { gap(from: $0, to: from) <= 12 },
                   "drawn to 0.5 the shaft has left the first box and no ink is within 10 pt of the second", "\(bounds(half))")
            let start = bounds(ink(of: shape, drawn: 0, size: size))
            expect(!start.isNull && start.width <= 6 && start.height <= 6, "a new arrow starts as a dot at most 6 pt across", "\(start)")
            expect(ink(of: shape, drawn: 1, size: size) == full, "rendering the same arrow twice gives identical pixels")
        }

        for (name, from, to) in [("overlapping", CGRect(x: 100, y: 60, width: 50, height: 30), CGRect(x: 130, y: 80, width: 50, height: 30)),
                                 ("nearly touching", CGRect(x: 60, y: 60, width: 50, height: 30), CGRect(x: 120, y: 60, width: 50, height: 30))] {
            let full = ink(of: .arrow(from: from, to: to), drawn: 1, size: CGSize(width: 300, height: 220))
            expect(!full.isEmpty && !full.contains { to.contains($0) } && full.contains { gap(from: $0, to: to) <= 12 },
                   "an arrow between \(name) boxes comes in from outside the box it points at, with ink within 12 pt of it", "\(bounds(full))")
        }
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
        let state = await waitForVoice("idle", pid: pid, seconds: 20)
        expect(state?.contains("voice=idle") ?? true, "the previous turn has ended in idle", state ?? "no state line in 2 minutes")

        let before = sample(upTo: 6, until: .arrow)
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

    static func chord(down: Bool) async {
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

    static func lastVoice(pid: Int32) -> String? {
        companionLog(pid: pid, categories: ["state"]).split(separator: "\n").last { $0.contains("state voice=") }.map(String.init)
    }

    static func waitForVoice(_ wanted: String, pid: Int32, seconds: Double) async -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        var state = lastVoice(pid: pid)
        while let line = state, !line.contains("voice=\(wanted)"), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            state = lastVoice(pid: pid)
        }
        return state
    }

    static func loggedField(_ key: String, in line: String?) -> Substring? {
        guard let line, let range = line.range(of: " \(key)=") else { return nil }
        return line[range.upperBound...].prefix { !$0.isWhitespace }
    }

    static func loggedNumbers(_ key: String, in line: String?) -> [Double] {
        loggedField(key, in: line)?.split(separator: ",").compactMap { Double($0) } ?? []
    }

    static func loggedPoint(_ key: String, in line: String?) -> CGPoint? {
        let fields = loggedNumbers(key, in: line)
        return fields.count == 2 ? CGPoint(x: fields[0], y: fields[1]) : nil
    }

    static func checkFlight(pid: Int32, voiceScenario: String) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        guard let display = NSScreen.screens.map(displayID).first(where: { CGDisplayBounds($0).contains(saved) }),
              let overlay = overlays(pid).first(where: { $0.bounds == CGDisplayBounds(display) })
        else {
            expect(false, "the display holding the pointer has an overlay", "pointer \(describe(saved))")
            return
        }
        let b = overlay.bounds
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        func appKit(_ local: CGPoint) -> CGPoint { CGPoint(x: b.minX + local.x, y: primaryHeight - b.minY - local.y) }
        func local(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - b.minX, y: primaryHeight - b.minY - point.y) }
        func follows(_ pointer: CGPoint) -> CGPoint { CGPoint(x: pointer.x - b.minX + 35, y: pointer.y - b.minY + 25) }

        let recorder = FrameRecorder(overlayWidth: b.width)
        guard let stream = await recorder.start(window: overlay.number) else {
            expect(false, "the overlay window can be streamed", "window \(overlay.number)")
            return
        }
        func glyphs(after time: Double, besides zones: [CGRect] = []) -> [(time: Double, centre: CGPoint)] {
            recorder.frames.filter { $0.time >= time }.compactMap { frame in frame.glyph(besides: zones).map { (frame.time, $0) } }
        }
        func settled(at point: CGPoint, besides zones: [CGRect] = []) -> Bool {
            let now = CACurrentMediaTime()
            let recent = glyphs(after: now - 0.5, besides: zones)
            return near(recorder.frames.last?.glyph(besides: zones), point, within: 2) && recent.allSatisfy { near($0.centre, point, within: 2) }
        }
        func ringPieces(_ frame: Frame?, in zone: CGRect) -> (box: CGRect, count: Int)? {
            let parts = frame?.blobs.filter { zone.contains($0.box) } ?? []
            guard let first = parts.first else { return nil }
            return (parts.dropFirst().reduce(first.box) { $0.union($1.box) }, parts.reduce(0) { $0 + $1.count })
        }
        func poll(upTo seconds: Double, every interval: Duration = .milliseconds(10), until done: () -> Bool) async -> Bool {
            let deadline = CACurrentMediaTime() + seconds
            while !done() {
                if CACurrentMediaTime() > deadline { return false }
                try? await Task.sleep(for: interval)
            }
            return true
        }
        func offCurve(_ centre: CGPoint, _ flight: Flight) -> CGFloat {
            let point = appKit(centre)
            return (0..<1000).map { step -> CGFloat in
                let on = flight.position(after: flight.duration * (Double(step) / 999))
                return hypot(on.x - point.x, on.y - point.y)
            }.min() ?? .infinity
        }
        func turnLines() -> [String] {
            let lines = companionLog(pid: pid, categories: ["companion", "transcription", "state"]).split(separator: "\n").map(String.init)
            return lines.lastIndex { $0.contains("state voice=listening") }.map { Array(lines[$0...]) } ?? []
        }
        func order(_ lines: [String]) -> [String] {
            lines.compactMap { line in ["flying", "landed", "pausing", "returning", "cancelled", "following"].first { line.contains("companion \($0)") } }
        }

        struct Outing {
            let released: Double
            let departed: Double
            let arrived: Double
            let from: CGPoint
            let to: CGPoint
            let target: CGPoint
            let bubble: CGRect
            let zone: CGRect
            let side: String
            let typed: Double
            let bounds: CGRect
            let ring: CGRect
            let ringZone: CGRect
            var zones: [CGRect] { [zone, ringZone] }
        }
        func pointOut(from home: CGPoint, onTakeoff: () async -> Void) async -> Outing? {
            await chord(down: true)
            try? await Task.sleep(for: .seconds(3))
            await chord(down: false)
            let released = CACurrentMediaTime()
            var departed: Double?
            _ = await poll(upTo: 15) {
                departed = glyphs(after: released).first { hypot($0.centre.x - home.x, $0.centre.y - home.y) > 20 }?.time
                return departed != nil
            }
            guard let departed else {
                expect(false, "the glyph took off within 15 s of the release")
                return nil
            }
            await onTakeoff()
            var lines: [String] = []
            _ = await poll(upTo: 10, every: .milliseconds(200)) {
                lines = turnLines()
                return lines.contains { $0.contains("companion pausing") }
            }
            let flying = lines.last { $0.contains("companion flying") }
            let named = lines.last { $0.contains("transcription pointing") }
            let pausing = lines.last { $0.contains("companion pausing") }
            let frame = loggedNumbers("bubble", in: pausing)
            let ringed = loggedField("mark", in: pausing)?.wholeMatch(of: #/ring:(.+)/#)?.output.1.split(separator: ",").compactMap { Double($0) } ?? []
            guard let from = loggedPoint("from", in: flying), let to = loggedPoint("to", in: flying), let target = loggedPoint("at", in: named),
                  frame.count == 4, let side = loggedField("side", in: pausing), let typed = loggedNumbers("typed", in: pausing).first,
                  ringed.count == 4
            else {
                expect(false, "the log names the flight, the point Claude named, the bubble and the ring",
                       "\(flying ?? "no companion flying line"); \(named ?? "no transcription pointing line"); \(pausing ?? "no companion pausing line")")
                return nil
            }
            let bubble = CGRect(origin: local(CGPoint(x: frame[0], y: frame[1] + frame[3])), size: CGSize(width: frame[2], height: frame[3]))
            let zone = bubbleZone(bubble, side: String(side))
            let bounds = CGRect(x: ringed[0], y: ringed[1], width: ringed[2], height: ringed[3])
            let ring = CGRect(origin: local(CGPoint(x: bounds.minX, y: bounds.maxY)), size: bounds.size)
            let zones = [zone, ringZone(ring)]
            let destination = local(to)
            _ = await poll(upTo: 5) { settled(at: destination, besides: zones) }
            let arrived = glyphs(after: departed, besides: zones).first { near($0.centre, destination, within: 2) }?.time
            expect(arrived != nil, "the glyph landed on the destination",
                   "\(describe(recorder.frames.last?.glyph(besides: zones))) vs \(describe(destination))")
            return arrived.map { Outing(released: released, departed: departed, arrived: $0, from: from, to: to, target: target,
                                        bubble: bubble, zone: zone, side: String(side), typed: typed,
                                        bounds: bounds, ring: ring, ringZone: ringZone(ring)) }
        }

        let previous = try? String(contentsOfFile: voiceScenario, encoding: .utf8)
        try? "long\n".write(toFile: voiceScenario, atomically: true, encoding: .utf8)

        let state = await waitForVoice("idle", pid: pid, seconds: 20)
        expect(state?.contains("voice=idle") ?? true, "the previous turn has ended in idle", state ?? "no state line in 2 minutes")

        let pointer = CGPoint(x: b.minX + 150, y: b.maxY - 150)
        move(to: pointer)
        try? await Task.sleep(for: .milliseconds(800))
        let home = follows(pointer)
        var start = glyph(in: overlay)?.centre
        let deadline = Date().addingTimeInterval(6)
        while !near(start, home, within: 2), Date() < deadline {
            start = glyph(in: overlay)?.centre
        }
        expect(near(start, home, within: 2), "before the hold the glyph follows the pointer near the bottom-left corner",
               "\(describe(start)) vs \(describe(home))")

        func gesture() async {
            var jumped = 0.0
            guard let out = await pointOut(from: home, onTakeoff: {
                jumped = CACurrentMediaTime()
                move(to: CGPoint(x: pointer.x + 150, y: pointer.y))
                try? await Task.sleep(for: .milliseconds(100))
                move(to: pointer)
            }) else { return }
            let destination = local(out.to)
            let nudged = CGPoint(x: pointer.x + 40, y: pointer.y)
            move(to: nudged)
            try? await Task.sleep(for: .seconds(1))
            let held = recorder.frames.last?.glyph(besides: out.zones)
            let voice = lastVoice(pid: pid)
            expect(near(held, destination, within: 2), "while the voice responds the glyph stays on the spot, though the pointer moved",
                   "\(describe(held)) vs \(describe(destination))")
            expect(voice?.contains("voice=responding") ?? false, "the voice was still responding when that was read", voice ?? "no state line")
            expect(near(out.to, CGPoint(x: out.bounds.maxX + 35, y: out.bounds.minY - 25), within: 0.2),
                   "the companion flew to 35 right of and 25 below the bottom-right corner of the box Claude named",
                   "to \(describe(out.to)) for \(out.bounds)")
            expect(near(CGPoint(x: out.bounds.midX, y: out.bounds.midY), out.target, within: 1),
                   "the ring's bounds are centred on the point Claude named", "\(out.bounds) for \(describe(out.target))")

            let flight = Flight(from: out.from, to: out.to)
            let airborne = glyphs(after: out.released, besides: out.zones)
                .filter { $0.time < out.arrived && hypot($0.centre.x - home.x, $0.centre.y - home.y) > 12 }.map(\.centre)
            let farthest = airborne.map { offCurve($0, flight) }.max() ?? 0
            let highest = airborne.compactMap { centre -> CGFloat? in
                let point = appKit(centre)
                guard abs(out.to.x - out.from.x) >= 1 else { return nil }
                let along = (point.x - out.from.x) / (out.to.x - out.from.x)
                guard along > 0, along < 1 else { return nil }
                return point.y - (out.from.y + along * (out.to.y - out.from.y))
            }.max() ?? 0
            print(String(format: "  info %d frames in flight, highest %.1f pt above the line, at most %.1f pt from the curve",
                         airborne.count, highest, farthest))
            expect(jumped > out.departed && jumped < out.arrived, "the pointer jumped 150 pt while the glyph flew out",
                   String(format: "jump %.2f s after takeoff, landing %.2f s after", jumped - out.departed, out.arrived - out.departed))
            expect(airborne.count >= 10, "at least 10 frames caught the glyph between home and the destination", "\(airborne.count)")
            let worst = recorder.frames.filter { $0.time >= out.departed && $0.time < out.arrived }
                .max { ($0.glyph(besides: out.zones).map { offCurve($0, flight) } ?? 0) < ($1.glyph(besides: out.zones).map { offCurve($0, flight) } ?? 0) }
            expect(farthest <= 3, "every frame on the way out lies on the flight's curve, pointer jump or not",
                   String(format: "%.1f pt off it; the worst frame came %.2f s after takeoff, landing %.2f s after, with blobs ", farthest,
                          (worst?.time ?? 0) - out.departed, out.arrived - out.departed)
                       + "\(worst?.blobs.map { "\($0.box) x\($0.count)" } ?? []) besides \(out.zones)")
            expect(highest > 5, "mid-flight the glyph rose above the straight line from start to destination",
                   String(format: "at most %.1f pt above it", highest))

            let landed = recorder.frames.last
            let blob = landed?.bubble(in: out.zone)
            let spot = landed?.glyph(besides: out.zones)
            expect(blob != nil && near(spot, destination, within: 2), "after landing a bubble shows inside its logged frame, beside the glyph on the spot",
                   "blobs \(landed?.blobs.map { "\($0.box)" } ?? []), zone \(out.zone), glyph \(describe(spot))")
            expect(blob.map { out.side == "right" ? $0.box.minX > destination.x : $0.box.maxX < destination.x } ?? false,
                   "the bubble sits on the \(out.side) side of the glyph, as logged", "\(String(describing: blob?.box)) vs glyph x \(destination.x)")
            let read = text(in: out.bubble.insetBy(dx: -2, dy: -2), of: overlay)
            expect(read.lowercased().contains("panel"), "Vision reads the label panel in the bubble", "read \"\(read)\"")
            let ringed = ringPieces(landed, in: out.ringZone)
            expect(ringed.map { $0.box.minX <= out.ring.minX - 1 && $0.box.minY <= out.ring.minY - 1
                                    && $0.box.maxX >= out.ring.maxX + 1 && $0.box.maxY >= out.ring.maxY + 1 } ?? false,
                   "while it pauses the ring surrounds the logged ring frame with at least 1 pt clear on every side",
                   "\(landed?.blobs.filter { out.ringZone.contains($0.box) }.map { "\($0.box) x\($0.count)" } ?? []) vs \(out.ring)")
            let drawing = recorder.frames.filter { $0.time >= out.arrived - 0.1 }.compactMap { ringPieces($0, in: out.ringZone)?.count }
            print("  info the ring showed \(drawing.prefix(24).map(String.init).joined(separator: " ")) opaque pixels in its first frames, "
                  + "in \(landed?.blobs.filter { out.ringZone.contains($0.box) }.count ?? 0) pieces once drawn")
            expect((drawing.first ?? .max) < (ringed?.count ?? 0) * 4 / 5, "the ring drew itself on: its first frame had under 4/5 of its pixels",
                   "\(drawing.first.map(String.init) ?? "no frame") of \(ringed?.count ?? 0)")

            let idle = await waitForVoice("idle", pid: pid, seconds: 20)
            expect(idle?.contains("voice=idle") ?? false, "the voice finished and the state went back to idle", idle ?? "no state line")
            let homeTo = follows(nudged)
            var leftSpot: Double?
            _ = await poll(upTo: 8) {
                leftSpot = glyphs(after: out.arrived, besides: out.zones).first { !near($0.centre, destination, within: 2) }?.time
                return leftSpot != nil
            }
            _ = await poll(upTo: 5) { settled(at: homeTo) }
            let returning = turnLines().last { $0.contains("companion returning") }
            let paused = loggedNumbers("paused", in: returning).first
            expect(paused.map { $0 >= out.typed + 3000 } ?? false, "the glyph stayed at least 3 s after typing the label",
                   "paused \(paused.map { "\(Int($0)) ms" } ?? "not logged"), typed \(Int(out.typed)) ms")
            if let leftSpot, let from = loggedPoint("from", in: returning), let to = loggedPoint("to", in: returning) {
                expect(near(from, out.to, within: 0.2) && near(to, appKit(homeTo), within: 0.2),
                       "it flew home from the spot to where following puts the pointer", "\(describe(from)) to \(describe(to))")
                let back = Flight(from: from, to: to)
                let reached = glyphs(after: leftSpot).first { near($0.centre, homeTo, within: 2) }?.time ?? .infinity
                let homeward = glyphs(after: leftSpot, besides: out.zones).filter { $0.time < reached }.map(\.centre)
                let off = homeward.map { offCurve($0, back) }.max() ?? 0
                let worstHome = recorder.frames.filter { $0.time >= leftSpot && $0.time < reached }
                    .max { ($0.glyph(besides: out.zones).map { offCurve($0, back) } ?? 0) < ($1.glyph(besides: out.zones).map { offCurve($0, back) } ?? 0) }
                expect(homeward.count >= 5 && off <= 3, "every frame on the way home lies on the arc from the spot to the pointer",
                       String(format: "%d frames, at most %.1f pt off it; the worst came %.2f s after leaving, with blobs ", homeward.count, off,
                              (worstHome?.time ?? 0) - leftSpot)
                           + "\(worstHome?.blobs.map { "\($0.box) x\($0.count)" } ?? []) besides \(out.zones)")
                let lastBubble = recorder.frames.last { $0.time >= out.arrived && $0.bubble(in: out.zone) != nil }?.time
                expect(lastBubble.map { $0 <= leftSpot + 0.6 } ?? false && recorder.frames.last?.bubble(in: out.zone) == nil,
                       "the bubble is gone within 0.6 s of the glyph leaving the spot",
                       lastBubble.map { String(format: "last seen %.2f s after", $0 - leftSpot) } ?? "never seen")
                let lastRing = recorder.frames.last { $0.time >= out.arrived && ringPieces($0, in: out.ringZone) != nil }?.time
                expect(lastRing.map { $0 <= leftSpot + 0.6 } ?? false && ringPieces(recorder.frames.last, in: out.ringZone) == nil,
                       "the ring is gone within 0.6 s of the glyph leaving the spot, and stays gone once it is home",
                       lastRing.map { String(format: "last seen %.2f s after", $0 - leftSpot) } ?? "never seen")
            } else {
                expect(false, "the glyph left the spot and the log names the flight home", returning ?? "no companion returning line")
            }

            let later = CGPoint(x: nudged.x, y: nudged.y - 30)
            move(to: later)
            try? await Task.sleep(for: .milliseconds(800))
            let again = recorder.frames.last?.glyph(besides: [])
            expect(near(again, follows(later), within: 2), "home again, the glyph follows the pointer",
                   "\(describe(again)) vs \(describe(follows(later)))")
            let logged = order(turnLines())
            expect(logged == ["flying", "landed", "pausing", "returning", "landed", "following"],
                   "the companion logged flying, landed, pausing, returning, landed and following, in that order", logged.joined(separator: ", "))
        }

        func cancel() async {
            try? "ok\n".write(toFile: voiceScenario, atomically: true, encoding: .utf8)
            move(to: pointer)
            try? await Task.sleep(for: .milliseconds(800))
            guard let out = await pointOut(from: home, onTakeoff: {}) else { return }
            let destination = local(out.to)
            var leaving: Double?
            let left = await poll(upTo: 10) {
                leaving = glyphs(after: out.arrived, besides: out.zones).first { !near($0.centre, destination, within: 2) }?.time
                return leaving != nil
            }
            let shifted = CGPoint(x: pointer.x + 120, y: pointer.y)
            move(to: shifted)
            let moved = CACurrentMediaTime()
            guard left, let leaving else {
                expect(false, "the glyph left the spot to fly home within 10 s of landing")
                return
            }
            let drawing = recorder.frames.filter { $0.time >= out.arrived - 0.1 && $0.time < leaving }.compactMap { ringPieces($0, in: out.ringZone)?.count }
            expect((drawing.first ?? .max) < (drawing.max() ?? 0) * 4 / 5, "a second ring also draws itself on, without first flashing whole",
                   "first frames \(drawing.prefix(8).map(String.init).joined(separator: " ")) of \(drawing.max() ?? 0)")
            try? await Task.sleep(for: .seconds(1.5))
            let target = follows(shifted)
            let reached = glyphs(after: moved, besides: out.zones).first { near($0.centre, target, within: 3) }?.time
            print(String(format: "  info the pointer moved %.0f ms after the glyph left the spot", (moved - leaving) * 1000))
            if moved - leaving > 1, let early = recorder.frames.first(where: { $0.time == leaving }) {
                print(String(format: "  info the frame that read as leaving came %.2f s after landing: glyph %@ vs %@, blobs ", leaving - out.arrived,
                             describe(early.glyph(besides: out.zones)), describe(destination))
                      + "\(early.blobs.map { "\($0.box) x\($0.count)" }) besides \(out.zones)")
            }
            expect(reached.map { $0 - moved <= 0.5 } ?? false, "a 120 pt pointer move on the way home brings the glyph to the pointer within 0.5 s",
                   reached.map { String(format: "after %.2f s", $0 - moved) } ?? describe(recorder.frames.last?.glyph(besides: out.zones)))
            expect(near(recorder.frames.last?.glyph(besides: out.zones), target, within: 2), "and it stays there, following",
                   "\(describe(recorder.frames.last?.glyph(besides: out.zones))) vs \(describe(target))")
            let lines = turnLines()
            let paused = loggedNumbers("paused", in: lines.last { $0.contains("companion returning") }).first
            expect(paused.map { $0 >= out.typed + 3000 && $0 <= out.typed + 3600 } ?? false,
                   "with a short voice the hold decides the pause: 3 s after typing",
                   "paused \(paused.map { "\(Int($0)) ms" } ?? "not logged"), typed \(Int(out.typed)) ms")
            let logged = order(lines)
            expect(logged == ["flying", "landed", "pausing", "returning", "cancelled", "following"],
                   "the flight home was cancelled, not landed", logged.joined(separator: ", "))
        }

        await gesture()
        await cancel()
        try? await stream.stopCapture()

        if let previous {
            try? previous.write(toFile: voiceScenario, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: voiceScenario)
        }
        move(to: saved)
        try? await Task.sleep(for: .milliseconds(300))
    }

    static func activeTaps(_ pid: Int32) -> [CGEventTapInformation] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        return taps.prefix(Int(count)).filter { $0.tappingProcess == pid && $0.options == .defaultTap }
    }

    static func isInk(_ pixels: Pixels, _ index: Int) -> Bool {
        let p = pixels.rgba
        return p[index + 3] >= 200 && p[index] >= 180 && p[index + 1] <= 90 && p[index + 2] <= 90
    }

    static func inked(_ pixels: Pixels, at pixel: CGPoint) -> Bool {
        let (x, y) = (Int(pixel.x), Int(pixel.y))
        return (y - 1...y + 1).contains { row in
            (x - 1...x + 1).contains { column in
                (0..<pixels.width).contains(column) && (0..<pixels.height).contains(row) && isInk(pixels, (row * pixels.width + column) * 4)
            }
        }
    }

    static func inkCount(_ pixels: Pixels) -> Int {
        stride(from: 0, to: pixels.rgba.count, by: 4).filter { isInk(pixels, $0) }.count
    }

    static func glyphBesideInk(_ pixels: Pixels, scale: Double) -> CGPoint? {
        var (sumX, sumY, count) = (0.0, 0.0, 0)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let index = (y * pixels.width + x) * 4
                guard pixels.rgba[index + 3] >= 230, !isInk(pixels, index) else { continue }
                sumX += Double(x) + 0.5
                sumY += Double(y) + 0.5
                count += 1
            }
        }
        return count > 0 ? CGPoint(x: sumX / Double(count) / scale, y: sumY / Double(count) / scale) : nil
    }

    static func requestCount(_ directory: String) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    static func newestFirstImage(_ directory: String) -> CGImage? {
        let numbers = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .compactMap { $0.hasSuffix(".json") ? Int($0.dropLast(5)) : nil }
        guard let newest = numbers.max(),
              let body = try? Data(contentsOf: URL(fileURLWithPath: directory).appending(path: "\(newest).json")),
              let messages = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]],
              let content = messages.last?["content"] as? [[String: Any]],
              let image = content.first(where: { $0["type"] as? String == "image" }),
              let base64 = (image["source"] as? [String: Any])?["data"] as? String,
              let jpeg = Data(base64Encoded: base64),
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func checkInk(pid: Int32, requests: String, hearing: String, staleSeconds: Double) async {
        let saved = CGEvent(source: nil)?.location ?? .zero
        let main = CGMainDisplayID()
        let b = CGDisplayBounds(main)
        guard let screen = NSScreen.screens.first(where: { displayID($0) == main }),
              let overlay = overlays(pid).first(where: { $0.bounds == b })
        else {
            expect(false, "the primary display has an overlay")
            return
        }
        let idle = await waitForVoice("idle", pid: pid, seconds: 20)
        expect(idle?.contains("voice=idle") ?? true, "the previous turn has ended in idle", idle ?? "no state line in 2 minutes")

        let victim = RecordingView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let panel = NSPanel(
            contentRect: NSRect(x: screen.frame.midX - 200, y: screen.frame.midY - 150, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = victim
        panel.orderFrontRegardless()
        defer { panel.close() }
        let previousHearing = try? String(contentsOfFile: hearing, encoding: .utf8)
        func hear(_ mode: String) { try? "\(mode)\n".write(toFile: hearing, atomically: true, encoding: .utf8) }

        let primaryHeight = b.height
        let centre = CGPoint(x: b.midX, y: b.midY)
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: centre.x + dx, y: centre.y + dy) }
        func local(_ quartz: CGPoint) -> CGPoint { CGPoint(x: quartz.x - b.minX, y: quartz.y - b.minY) }
        func logged(_ quartz: CGPoint) -> String { String(format: "%.1f,%.1f", quartz.x, primaryHeight - quartz.y) }
        let chorded: CGEventFlags = [.maskControl, .maskAlternate]
        func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags) {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        func drag(from start: CGPoint, steps: Int, flags: CGEventFlags) async -> CGPoint {
            var point = start
            for _ in 0..<steps {
                point.x += 12
                post(.leftMouseDragged, at: point, flags: flags)
                try? await Task.sleep(for: .milliseconds(10))
            }
            return point
        }
        func inkLines() -> [String] {
            companionLog(pid: pid, categories: ["ink", "screenshot", "state", "transcription"]).split(separator: "\n").map(String.init)
        }
        func overlayShot() -> (pixels: Pixels, scale: Double)? { capture(overlay) }
        func onOverlay(_ shot: (pixels: Pixels, scale: Double)?, _ quartz: CGPoint) -> Bool {
            guard let shot else { return false }
            let point = local(quartz)
            return inked(shot.pixels, at: CGPoint(x: point.x * shot.scale, y: point.y * shot.scale))
        }

        let dot = at(-150, -80)
        let firstStart = at(-120, -40)
        let secondStart = at(-120, 40)
        let drawn = [dot, at(-72, -40), at(-90, 40)]
        hear("silent")
        move(to: at(-160, -100))
        try? await Task.sleep(for: .milliseconds(300))
        let requestsBefore = requestCount(requests)

        await chord(down: true)
        let chordDown = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(50))
        post(.leftMouseDown, at: dot, flags: chorded)
        try? await Task.sleep(for: .milliseconds(10))
        post(.leftMouseUp, at: dot, flags: chorded)
        try? await Task.sleep(for: .milliseconds(20))
        post(.leftMouseDown, at: firstStart, flags: chorded)
        try? await Task.sleep(for: .milliseconds(10))
        let firstEnd = await drag(from: firstStart, steps: 8, flags: chorded)
        post(.leftMouseUp, at: firstEnd, flags: chorded)
        try? await Task.sleep(until: chordDown + .milliseconds(400), clock: .continuous)
        let listening = await waitForVoice("listening", pid: pid, seconds: 5)
        expect(listening?.contains("voice=listening") ?? false, "the chord became a hold", listening ?? "no state line")
        let drawing = loggedField("utterance", in: listening).map(String.init) ?? "?"

        try? await Task.sleep(until: chordDown + .milliseconds(1500), clock: .continuous)
        post(.leftMouseDown, at: secondStart, flags: chorded)
        try? await Task.sleep(for: .milliseconds(10))
        let sealedAt = await drag(from: secondStart, steps: 5, flags: chorded)
        try? await Task.sleep(for: .milliseconds(300))
        let pen = activeTaps(pid)
        expect(pen.count == 1 && pen.allSatisfy { $0.enabled && $0.eventsOfInterest == 70 },
               "mid-chord the app has one enabled active tap on left down, up and drag (mask 70)",
               "\(pen.map { "enabled \($0.enabled) mask \($0.eventsOfInterest)" })")
        let held = overlayShot()
        let glyph = held.flatMap { glyphBesideInk($0.pixels, scale: $0.scale) }
        let following = CGPoint(x: sealedAt.x - b.minX + 35, y: sealedAt.y - b.minY + 25)
        expect(near(glyph, following, within: 2), "while drawing, the glyph followed the drags, so they reached it as moves",
               "\(describe(glyph)) vs \(describe(following))")
        expect(drawn.allSatisfy { onOverlay(held, $0) }, "mid-hold the overlay shows the dot, the first stroke and the second stroke so far")

        try? await Task.sleep(until: chordDown + .milliseconds(3000), clock: .continuous)
        let chordUp = ContinuousClock.now
        await chord(down: false)
        let finalPoint = await drag(from: sealedAt, steps: 5, flags: [])
        post(.leftMouseUp, at: finalPoint, flags: [])
        try? await Task.sleep(for: .milliseconds(150))
        expect(activeTaps(pid).isEmpty, "150 ms after the last up the pen's tap is gone", "\(activeTaps(pid).count) active taps")
        expect(victim.downs == 0 && victim.ups == 0 && victim.drags == 0, "the window under the pen got no down, up or drag",
               "down \(victim.downs) up \(victim.ups) drag \(victim.drags)")

        let quiet = await waitForVoice("idle", pid: pid, seconds: 10)
        let delivered = inkLines().last { $0.contains("transcription delivered ") && $0.contains(" utterance=\(drawing) ") }
        expect((quiet?.contains("voice=idle") ?? false) && (delivered?.hasSuffix("text=") ?? false),
               "the hold that only drew heard no words and went idle", "\(quiet ?? "no state line"); \(delivered ?? "no delivered line")")
        let sentFirst = inkLines().last { $0.contains("ink sent utterance=\(drawing) ") }
        let through = loggedField("through", in: sentFirst).map(String.init) ?? "?"
        expect(sentFirst != nil, "its release sent the ink with utterance \(drawing)", "no ink sent line")
        try? await Task.sleep(until: chordUp + .milliseconds(2900), clock: .continuous)
        postModifier(59, down: true, flags: .maskControl)
        try? await Task.sleep(until: chordUp + .milliseconds(3000), clock: .continuous)
        let kept = overlayShot()
        expect(drawn.allSatisfy { onOverlay(kept, $0) }, "3 s after that idle hold the ink is still on the overlay")
        expect(!onOverlay(kept, at(-24, 40)) && !onOverlay(kept, finalPoint), "drags after the chord went up drew nothing")

        hear("heard")
        postModifier(58, down: true, flags: chorded)
        let askDown = ContinuousClock.now
        try? await Task.sleep(until: askDown + .milliseconds(2500), clock: .continuous)
        await chord(down: false)
        try? await Task.sleep(for: .milliseconds(150))
        let asking = overlayShot()
        let voice = lastVoice(pid: pid)
        expect(voice?.contains("voice=processing") ?? false, "that overlay was read while the voice was processing", voice ?? "no state line")
        expect(drawn.allSatisfy { onOverlay(asking, $0) }, "while the question is processed the ink is still on the overlay")
        let sentSecond = inkLines().last { $0.contains("ink sent ") }
        let asked = loggedField("utterance", in: sentSecond).map(String.init) ?? "?"
        expect(asked != drawing && loggedField("through", in: sentSecond).map(String.init) == through,
               "the asking hold is a new utterance sent with the same strokes, through=\(through)", sentSecond ?? "no ink sent line")

        let deadline = Date().addingTimeInterval(15)
        while requestCount(requests) == requestsBefore, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let image = requestCount(requests) > requestsBefore ? newestFirstImage(requests) : nil, let pixels = decode(image) {
            func pixel(_ quartz: CGPoint) -> CGPoint {
                CGPoint(x: (quartz.x - b.minX) * Double(image.width) / b.width, y: (quartz.y - b.minY) * Double(image.height) / b.height)
            }
            for (name, point) in zip(["the dot", "the first stroke", "the second stroke before the release"], drawn) {
                expect(inked(pixels, at: pixel(point)), "Claude's screenshot has \(name) in red",
                       "at pixel \(describe(pixel(point))) of \(image.width)x\(image.height)")
            }
            expect([at(-24, 40), finalPoint, at(100, -40)].allSatisfy { !inked(pixels, at: pixel($0)) },
                   "and no red past the release or 100 pt beside the strokes")
        } else {
            expect(false, "Claude got a request with a screenshot within 15 s of the asking release", "\(requestCount(requests)) requests, \(requestsBefore) before")
        }
        let lines = inkLines()
        let strokes = lines.filter { $0.contains("ink stroke ") }.suffix(3).map { line in
            [loggedField("points", in: line), loggedField("from", in: line), loggedField("sealed", in: line)].map { $0.map(String.init) ?? "?" }
        }
        let expected = [["1", logged(dot), "no"], ["9", logged(firstStart), "no"], ["6", logged(secondStart), "yes"]]
        expect(strokes == expected, "the log has the dot, the 9-point stroke and the sealed 6-point stroke, from where they were posted",
               "\(strokes) vs \(expected)")
        let inkedLine = lines.last { $0.contains("screenshot inked ") }
        expect(inkedLine?.hasSuffix("display=\(main) strokes=3") ?? false, "the screenshot of the primary display was inked with 3 strokes",
               inkedLine ?? "no screenshot inked line")
        let labelled = lines.last { $0.contains("screenshot labelled display=\(main) ") }
        expect(labelled?.contains(". The user drew the red marks on this screen to show you what they mean. When they say \"this\", they mean what they marked. This image is ") ?? false,
               "its label tells Claude the user drew the red marks", labelled ?? "no screenshot labelled line")

        let clearedBefore = inkLines().filter { $0.contains("ink cleared ") }.count
        let done = await waitForVoice("idle", pid: pid, seconds: 20)
        expect(done?.contains("voice=idle") ?? false, "the answer finished and the voice went idle", done ?? "no state line")
        try? await Task.sleep(for: .milliseconds(600))
        let spent = overlayShot().map { inkCount($0.pixels) }
        expect(spent == 0, "0.6 s after the answer the ink it was asked with is gone", "\(spent.map(String.init) ?? "no capture") red pixels")
        expect(inkLines().filter { $0.contains("ink cleared ") }.count == clearedBefore, "the answer spent it, not the stale clear")

        let listeningBefore = inkLines().filter { $0.contains("state voice=listening") }.count
        let requestsBeforeQuick = requestCount(requests)
        let quickStart = at(-120, -100)
        let quickMiddle = at(-90, -100)
        move(to: quickStart)
        try? await Task.sleep(for: .milliseconds(300))
        await chord(down: true)
        let quickDown = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(50))
        post(.leftMouseDown, at: quickStart, flags: chorded)
        try? await Task.sleep(for: .milliseconds(10))
        let quickEnd = await drag(from: quickStart, steps: 5, flags: chorded)
        post(.leftMouseUp, at: quickEnd, flags: chorded)
        try? await Task.sleep(until: quickDown + .milliseconds(200), clock: .continuous)
        let quickUp = ContinuousClock.now
        await chord(down: false)
        try? await Task.sleep(until: quickUp + .seconds(1), clock: .continuous)
        let quick = overlayShot()
        expect(onOverlay(quick, quickMiddle) && !drawn.contains { onOverlay(quick, $0) },
               "a chord let go inside the shortcut window keeps its stroke, and the answered strokes stay gone")
        expect(activeTaps(pid).isEmpty, "and holds no active tap", "\(activeTaps(pid).count)")
        expect(inkLines().filter { $0.contains("state voice=listening") }.count == listeningBefore && requestCount(requests) == requestsBeforeQuick,
               "no hold began and Claude was not asked")
        expect(victim.downs == 0 && victim.ups == 0 && victim.drags == 0, "the window under the pen still got nothing",
               "down \(victim.downs) up \(victim.ups) drag \(victim.drags)")
        try? await Task.sleep(until: quickUp + .seconds(staleSeconds - 0.8), clock: .continuous)
        expect(onOverlay(overlayShot(), quickMiddle), "0.8 s before the stale time the stroke is still there")
        try? await Task.sleep(until: quickUp + .seconds(staleSeconds + 1), clock: .continuous)
        let stale = overlayShot().map { inkCount($0.pixels) }
        let cleared = inkLines().last { $0.contains("ink cleared ") }
        expect(stale == 0 && (cleared?.hasSuffix("ink cleared reason=stale strokes=1") ?? false),
               "1 s after the stale time the unused stroke was cleared", "\(stale.map(String.init) ?? "no capture") red pixels; \(cleared ?? "no ink cleared line")")

        let control = at(100, 0)
        move(to: control)
        try? await Task.sleep(for: .milliseconds(100))
        post(.leftMouseDown, at: control, flags: [])
        try? await Task.sleep(for: .milliseconds(20))
        post(.leftMouseUp, at: control, flags: [])
        try? await Task.sleep(for: .milliseconds(300))
        expect(victim.downs == 1 && victim.ups == 1, "a plain click on the same window reaches it", "down \(victim.downs) up \(victim.ups)")

        hear(previousHearing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ok")
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
