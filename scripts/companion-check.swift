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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
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

nonisolated struct Frame {
    let time: Double
    let blobs: [Blob]

    func bubble(in zone: CGRect?) -> Blob? {
        guard let zone else { return nil }
        return blobs.first { zone.contains($0.box) }
    }

    func glyph(besides zone: CGRect?) -> CGPoint? {
        let parts = blobs.filter { blob in zone.map { !$0.contains(blob.box) } ?? true }
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
        recorded.append(Frame(time: CACurrentMediaTime(), blobs: Array(found.prefix(8))))
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
            } else {
                checkPlacement()
                checkArc()
                checkBubble()
                await checkPointing()
                checkLooksRender()
                checkBubbleRender()
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
        let callout = Callout(point: target, label: "panel")
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
        companion.point(at: Callout(point: topLeft, label: "Wi-Fi"))
        await wait(until: second + .milliseconds(200))
        companion.point(at: nil)
        await wait(until: second + early.duration + .milliseconds(150))
        expect(distance(companion.position, spot(topLeft)) <= 0.001 && companion.bubble?.label == "Wi-Fi",
               "a voice that stops mid-flight still lands with the bubble up", "\(exact(companion.position)), \(String(describing: companion.bubble))")
        let returning = await wait(upTo: .seconds(1)) { companion.bubble == nil }
        await wait(until: .now + .milliseconds(100))
        let turned = companion.position
        let retargeted = ContinuousClock.now
        companion.point(at: Callout(point: topRight, label: "switch"))
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
        companion.point(at: Callout(point: bottomRight, label: "panel"))
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
        expect(dot.count == 1 && near(dot.first?.centre, CGPoint(x: 100, y: 50), within: 0.5),
               "a one-point stroke at -100,350 is a dot centred on 100,50", "\(dot.map { "\($0.box)" })")
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
        let glyph = sampled.glyph(besides: zone)
        expect(sampled.bubble(in: zone) != nil && near(glyph, Companion.local(spot, in: overlay), within: 1),
               "at the stream's scale the glyph and the bubble beside it read as separate blobs",
               "\(sampled.blobs.map { "\($0.box) x\($0.count)" }), glyph \(describe(glyph))")
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
        func glyphs(after time: Double, besides zone: CGRect? = nil) -> [(time: Double, centre: CGPoint)] {
            recorder.frames.filter { $0.time >= time }.compactMap { frame in frame.glyph(besides: zone).map { (frame.time, $0) } }
        }
        func settled(at point: CGPoint, besides zone: CGRect? = nil) -> Bool {
            let now = CACurrentMediaTime()
            let recent = glyphs(after: now - 0.5, besides: zone)
            return near(recorder.frames.last?.glyph(besides: zone), point, within: 2) && recent.allSatisfy { near($0.centre, point, within: 2) }
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
            guard let from = loggedPoint("from", in: flying), let to = loggedPoint("to", in: flying), let target = loggedPoint("at", in: named),
                  frame.count == 4, let side = loggedField("side", in: pausing), let typed = loggedNumbers("typed", in: pausing).first
            else {
                expect(false, "the log names the flight, the point Claude named and the bubble",
                       "\(flying ?? "no companion flying line"); \(named ?? "no transcription pointing line"); \(pausing ?? "no companion pausing line")")
                return nil
            }
            let bubble = CGRect(origin: local(CGPoint(x: frame[0], y: frame[1] + frame[3])), size: CGSize(width: frame[2], height: frame[3]))
            let zone = bubbleZone(bubble, side: String(side))
            let destination = local(to)
            _ = await poll(upTo: 5) { settled(at: destination, besides: zone) }
            let arrived = glyphs(after: departed, besides: zone).first { near($0.centre, destination, within: 2) }?.time
            expect(arrived != nil, "the glyph landed on the destination",
                   "\(describe(recorder.frames.last?.glyph(besides: zone))) vs \(describe(destination))")
            return arrived.map { Outing(released: released, departed: departed, arrived: $0, from: from, to: to, target: target,
                                        bubble: bubble, zone: zone, side: String(side), typed: typed) }
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
            let held = recorder.frames.last?.glyph(besides: out.zone)
            let voice = lastVoice(pid: pid)
            expect(near(held, destination, within: 2), "while the voice responds the glyph stays on the spot, though the pointer moved",
                   "\(describe(held)) vs \(describe(destination))")
            expect(voice?.contains("voice=responding") ?? false, "the voice was still responding when that was read", voice ?? "no state line")
            expect(near(out.to, CGPoint(x: out.target.x + 35, y: out.target.y - 25), within: 0.2),
                   "the companion flew to 35 right of and 25 below the point Claude named",
                   "to \(describe(out.to)) for \(describe(out.target))")

            let flight = Flight(from: out.from, to: out.to)
            let airborne = glyphs(after: out.released, besides: out.zone)
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
            expect(farthest <= 3, "every frame on the way out lies on the flight's curve, pointer jump or not", String(format: "%.1f pt off it", farthest))
            expect(highest > 5, "mid-flight the glyph rose above the straight line from start to destination",
                   String(format: "at most %.1f pt above it", highest))

            let landed = recorder.frames.last
            let blob = landed?.bubble(in: out.zone)
            let spot = landed?.glyph(besides: out.zone)
            expect(blob != nil && near(spot, destination, within: 2), "after landing a bubble shows inside its logged frame, beside the glyph on the spot",
                   "blobs \(landed?.blobs.map { "\($0.box)" } ?? []), zone \(out.zone), glyph \(describe(spot))")
            expect(blob.map { out.side == "right" ? $0.box.minX > destination.x : $0.box.maxX < destination.x } ?? false,
                   "the bubble sits on the \(out.side) side of the glyph, as logged", "\(String(describing: blob?.box)) vs glyph x \(destination.x)")
            let read = text(in: out.bubble.insetBy(dx: -2, dy: -2), of: overlay)
            expect(read.lowercased().contains("panel"), "Vision reads the label panel in the bubble", "read \"\(read)\"")

            let idle = await waitForVoice("idle", pid: pid, seconds: 20)
            expect(idle?.contains("voice=idle") ?? false, "the voice finished and the state went back to idle", idle ?? "no state line")
            let homeTo = follows(nudged)
            var leftSpot: Double?
            _ = await poll(upTo: 8) {
                leftSpot = glyphs(after: out.arrived, besides: out.zone).first { !near($0.centre, destination, within: 2) }?.time
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
                let homeward = glyphs(after: leftSpot, besides: out.zone).filter { $0.time < reached }.map(\.centre)
                let off = homeward.map { offCurve($0, back) }.max() ?? 0
                expect(homeward.count >= 5 && off <= 3, "every frame on the way home lies on the arc from the spot to the pointer",
                       String(format: "%d frames, at most %.1f pt off it", homeward.count, off))
                let lastBubble = recorder.frames.last { $0.time >= out.arrived && $0.bubble(in: out.zone) != nil }?.time
                expect(lastBubble.map { $0 <= leftSpot + 0.6 } ?? false && recorder.frames.last?.bubble(in: out.zone) == nil,
                       "the bubble is gone within 0.6 s of the glyph leaving the spot",
                       lastBubble.map { String(format: "last seen %.2f s after", $0 - leftSpot) } ?? "never seen")
            } else {
                expect(false, "the glyph left the spot and the log names the flight home", returning ?? "no companion returning line")
            }

            let later = CGPoint(x: nudged.x, y: nudged.y - 30)
            move(to: later)
            try? await Task.sleep(for: .milliseconds(800))
            let again = recorder.frames.last?.glyph(besides: nil)
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
                leaving = glyphs(after: out.arrived, besides: out.zone).first { !near($0.centre, destination, within: 2) }?.time
                return leaving != nil
            }
            let shifted = CGPoint(x: pointer.x + 120, y: pointer.y)
            move(to: shifted)
            let moved = CACurrentMediaTime()
            guard left, let leaving else {
                expect(false, "the glyph left the spot to fly home within 10 s of landing")
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            let target = follows(shifted)
            let reached = glyphs(after: moved, besides: out.zone).first { near($0.centre, target, within: 3) }?.time
            print(String(format: "  info the pointer moved %.0f ms after the glyph left the spot", (moved - leaving) * 1000))
            expect(reached.map { $0 - moved <= 0.5 } ?? false, "a 120 pt pointer move on the way home brings the glyph to the pointer within 0.5 s",
                   reached.map { String(format: "after %.2f s", $0 - moved) } ?? describe(recorder.frames.last?.glyph(besides: out.zone)))
            expect(near(recorder.frames.last?.glyph(besides: out.zone), target, within: 2), "and it stays there, following",
                   "\(describe(recorder.frames.last?.glyph(besides: out.zone))) vs \(describe(target))")
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
