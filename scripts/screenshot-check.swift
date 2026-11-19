import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
enum ScreenshotCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ width: Int, _ height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
    }

    static func gradient(_ width: Int, _ height: Int) -> CGImage {
        let context = context(width, height)
        for x in stride(from: 0, to: width, by: 16) {
            context.setFillColor(CGColor(srgbRed: Double(x) / Double(width), green: 0.5, blue: Double(x % 64) / 64, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 16, height: height))
        }
        return context.makeImage()!
    }

    static func solid(_ width: Int, _ height: Int) -> CGImage {
        let context = context(width, height)
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func luminanceQuantizers(_ jpeg: Data) -> [Int] {
        let bytes = [UInt8](jpeg)
        var i = 2
        while i + 4 < bytes.count, bytes[i] == 0xFF {
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if bytes[i + 1] == defineQuantizationTable { return bytes[(i + 5)..<(i + 5 + pinned.count)].map(Int.init) }
            i += 2 + length
        }
        return []
    }

    static func decoded(_ jpeg: Data) -> CGImage? {
        CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func type(of jpeg: Data) -> String? {
        CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap(CGImageSourceGetType) as String?
    }

    static func isFlat(_ image: CGImage) -> Bool {
        let context = context(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        let first = Array(pixels.prefix(3))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 where abs(Int(pixels[offset + channel]) - Int(first[channel])) > flatTolerance { return false }
        }
        return true
    }

    static func main() async {
        if CommandLine.arguments.contains("--backdrop") {
            await backdrop()
            return
        }
        if CommandLine.arguments.contains("--markers") {
            await markers()
            return
        }
        if CommandLine.arguments.contains("--point") {
            await point()
            return
        }
        if CommandLine.arguments.contains("--live") {
            await live()
            return
        }
        checkFitting()
        checkEncoding()
        checkCursor()
        checkLabels()
        checkPoint()
        checkFailure()
        checkInk()
        exit(failures == 0 ? 0 : 1)
    }

    static func checkFitting() {
        print("fitting")
        func fit(_ width: Double, _ height: Double, scale: Double) -> Screenshot.Pixels {
            Screenshot.Pixels(fitting: CGSize(width: width, height: height), scale: scale)
        }
        expect(fit(1920, 1080, scale: 1) == .init(width: 1280, height: 720), "1920x1080 at 1x caps its width, got \(fit(1920, 1080, scale: 1))")
        expect(fit(1710, 1112, scale: 2) == .init(width: 1280, height: 832), "1710x1112 at 2x gives 1280x832, got \(fit(1710, 1112, scale: 2))")
        expect(fit(1080, 1920, scale: 1) == .init(width: 720, height: 1280), "a portrait display caps its height, got \(fit(1080, 1920, scale: 1))")
        expect(fit(1024, 768, scale: 1) == .init(width: 1024, height: 768), "a small display is never upscaled, got \(fit(1024, 768, scale: 1))")
        expect(fit(1024, 640, scale: 2) == .init(width: 1280, height: 800), "1024x640 at 2x is sized from pixels, got \(fit(1024, 640, scale: 2))")
        expect(fit(640, 400, scale: 2) == .init(width: 1280, height: 800), "640x400 at 2x is exactly the cap, got \(fit(640, 400, scale: 2))")
        expect(fit(0, 0, scale: 2) == .init(width: 1, height: 1), "a zero-size display still gets one pixel per axis, got \(fit(0, 0, scale: 2))")
        expect(fit(5000, 1, scale: 1) == .init(width: 1280, height: 1), "a sliver keeps at least one pixel on its short axis, got \(fit(5000, 1, scale: 1))")
    }

    static func checkEncoding() {
        print("encoding")
        let frame = CGRect(x: 97, y: -1112, width: 1710, height: 1112)
        let image = gradient(1280, 832)
        guard let shot = Screenshot(encoding: image, display: 7, appKitFrame: frame, cursor: .zero) else {
            expect(false, "a drawn 1280x832 image encodes")
            return
        }
        expect(shot.pixels == .init(width: 1280, height: 832), "pixels come from the image, got \(shot.pixels)")
        expect(shot.appKitFrame == frame, "the frame is kept as given, got \(shot.appKitFrame)")
        expect(shot.display == 7, "the display id is kept, got \(shot.display)")
        expect(Array(shot.jpeg.prefix(3)) == [0xFF, 0xD8, 0xFF], "the JPEG starts with FF D8 FF, got \(Array(shot.jpeg.prefix(3)))")
        expect(Array(shot.jpeg.suffix(2)) == [0xFF, 0xD9], "the JPEG ends with FF D9, got \(Array(shot.jpeg.suffix(2)))")
        expect(type(of: shot.jpeg) == "public.jpeg", "ImageIO reads the bytes as public.jpeg, got \(type(of: shot.jpeg) ?? "nil")")
        let back = decoded(shot.jpeg)
        expect(back?.width == 1280 && back?.height == 832, "the JPEG decodes at 1280x832, got \(back?.width ?? 0)x\(back?.height ?? 0)")
        expect(luminanceQuantizers(shot.jpeg) == pinned, "the luminance quantizers are the quality 0.8 table, got \(luminanceQuantizers(shot.jpeg))")
        expect(luminanceQuantizers(jpeg(image, quality: 0.75)) != pinned, "quality 0.75 gives a different table, got \(luminanceQuantizers(jpeg(image, quality: 0.75)))")
        expect(luminanceQuantizers(jpeg(image, quality: 0.85)) != pinned, "quality 0.85 gives a different table, got \(luminanceQuantizers(jpeg(image, quality: 0.85)))")
        expect(!isFlat(back!), "the gradient decodes as not one flat colour")
        let flat = Screenshot(encoding: solid(64, 64), display: 1, appKitFrame: CGRect(x: 0, y: 0, width: 64, height: 64), cursor: .zero)
        expect(flat.flatMap { decoded($0.jpeg) }.map(isFlat) == true, "a solid image decodes as one flat colour")
        let tiny = Screenshot(encoding: gradient(4, 2), display: 1, appKitFrame: CGRect(x: 0, y: 0, width: 1280, height: 640), cursor: .zero)
        expect(tiny?.pixels == .init(width: 4, height: 2), "a 4x2 image stays 4x2, so encoding never resizes, got \(String(describing: tiny?.pixels))")
    }

    static let mainFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    static let builtInFrame = CGRect(x: 97, y: -1112, width: 1710, height: 1112)

    static func shot(_ display: CGDirectDisplayID, _ frame: CGRect, cursor: CGPoint, size: (Int, Int) = (8, 8)) -> Screenshot {
        Screenshot(encoding: solid(size.0, size.1), display: display, appKitFrame: frame, cursor: cursor)!
    }

    static func checkCursor() {
        print("cursor")
        let flipped = Screenshot.appKitFrame(of: CGRect(x: 97, y: 1080, width: 1710, height: 1112), primaryHeight: 1080)
        expect(flipped == builtInFrame, "the built-in's top-left frame flips to \(builtInFrame), got \(flipped)")
        let same = Screenshot.appKitFrame(of: CGRect(x: 0, y: 0, width: 1920, height: 1080), primaryHeight: 1080)
        expect(same == mainFrame, "the main display maps to itself, got \(same)")
        func holders(_ x: Double, _ y: Double) -> [CGDirectDisplayID] {
            let at = CGPoint(x: x, y: y)
            return [shot(3, mainFrame, cursor: at), shot(1, builtInFrame, cursor: at)].filter(\.holdsCursor).map(\.display)
        }
        expect(holders(500, 1080) == [3], "the top pixel row of main is main's, got \(holders(500, 1080))")
        expect(holders(500, 0) == [1], "the top pixel row of the built-in is the built-in's, got \(holders(500, 0))")
        expect(holders(500, -1112).isEmpty, "one past the built-in's bottom is on neither, got \(holders(500, -1112))")
        expect(holders(1920, 500).isEmpty, "one past main's right edge is on neither, got \(holders(1920, 500))")
        let far = CGPoint(x: -5000, y: -5000)
        let onBuiltIn = CGPoint(x: 500, y: -500)
        let order = { (shots: [Screenshot]) in Screenshot.cursorFirst(shots).map(\.display) }
        let first = order([shot(3, mainFrame, cursor: onBuiltIn), shot(1, builtInFrame, cursor: onBuiltIn)])
        expect(first == [1, 3], "the cursor's screen moves first, got \(first)")
        let none = order([shot(3, mainFrame, cursor: far), shot(1, builtInFrame, cursor: far)])
        expect(none == [3, 1], "with no cursor screen the capture order stays, got \(none)")
        let already = order([shot(1, builtInFrame, cursor: onBuiltIn), shot(3, mainFrame, cursor: onBuiltIn)])
        expect(already == [1, 3], "a cursor screen already first stays first, got \(already)")
    }

    static func checkLabels() {
        print("labels")
        let cursor = CGPoint(x: 500, y: -500)
        let on = shot(1, builtInFrame, cursor: cursor, size: (1280, 832)).label(number: 1, of: 2)
        let want = "Screen 1 of 2. The cursor is on this screen. This image is 1280x832 pixels."
        expect(on == want, "the cursor screen reads '\(want)', got '\(on)'")
        let off = shot(3, mainFrame, cursor: cursor, size: (1280, 720)).label(number: 2, of: 2)
        let wantOff = "Screen 2 of 2. The cursor is not on this screen. This image is 1280x720 pixels."
        expect(off == wantOff, "the other screen reads '\(wantOff)', got '\(off)'")
    }

    static func checkPoint() {
        print("point")
        func at(_ frame: CGRect, _ size: (Int, Int), _ x: Int, _ y: Int) -> CGPoint {
            shot(1, frame, cursor: .zero, size: size).appKitCentre(ofPixelX: x, y: y)
        }
        func near(_ got: CGPoint, _ x: Double, _ y: Double) -> Bool {
            abs(got.x - x) <= 0.001 && abs(got.y - y) <= 0.001
        }
        func check(_ name: String, _ got: CGPoint, _ x: Double, _ y: Double) {
            expect(near(got, x, y), "\(name) is (\(x), \(y)), got (\(got.x), \(got.y))")
        }
        let main = (1280, 720)
        check("main top-left pixel", at(mainFrame, main, 0, 0), 0.75, 1079.25)
        check("main bottom-right pixel", at(mainFrame, main, 1279, 719), 1919.25, 0.75)
        check("main centre pixel", at(mainFrame, main, 640, 360), 960.75, 539.25)
        check("main far outside clamps to the bottom-left pixel", at(mainFrame, main, -5, 9999), 0.75, 0.75)
        let builtIn = (1280, 832)
        check("built-in top-left pixel", at(builtInFrame, builtIn, 0, 0), 97.66796875, -0.668269)
        check("built-in bottom-right pixel", at(builtInFrame, builtIn, 1279, 831), 1806.33203125, -1111.331731)
        check("built-in pixel 211,12", at(builtInFrame, builtIn, 211, 12), 379.55078125, -16.706731)
        check("built-in one past the corner clamps to the last pixel", at(builtInFrame, builtIn, 1280, 832), 1806.33203125, -1111.331731)
        check("retina without downsample", at(CGRect(x: 0, y: 0, width: 640, height: 400), (1280, 800), 2, 2), 1.25, 398.75)
        for (name, frame, size) in [("main", mainFrame, main), ("built-in", builtInFrame, builtIn)] {
            for (x, y) in [(0, 0), (size.0 - 1, 0), (0, size.1 - 1), (size.0 - 1, size.1 - 1)] {
                let p = at(frame, size, x, y)
                expect(frame.contains(p) && NSMouseInRect(p, frame, false), "\(name) corner pixel \(x),\(y) lands inside the frame, got \(p)")
            }
        }
    }

    static let pinned = [2, 2, 2, 2, 2, 2, 3, 2, 2, 3, 4, 3]
    static let defineQuantizationTable: UInt8 = 0xDB
    static let flatTolerance = 8

    static func checkFailure() {
        print("failure")
        expect(Screenshot.Failure.noAccess.logFields == "reason=noAccess", "no access renders its reason")
        expect(
            Screenshot.Failure.listing("WindowServer gone").logFields == "reason=listing detail=WindowServer gone",
            "a listing failure renders its detail last"
        )
    }

    static func white(_ width: Int, _ height: Int) -> CGImage {
        let context = context(width, height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func rgb(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let context = context(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = y * context.bytesPerRow + x * 4
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return [Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2])]
    }

    static func near(_ got: [Int], _ want: [Int], within tolerance: Int) -> Bool {
        zip(got, want).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func checkInk() {
        print("ink")
        let red = [255, 48, 43]
        let paper = [255, 255, 255]
        let frame = CGRect(x: 100, y: 50, width: 800, height: 400)
        let blank = white(400, 200)
        let line = Ink([Stroke(CGPoint(x: 300, y: 250), [CGPoint(x: 500, y: 250)])]).composited(onto: blank, appKitFrame: frame)
        expect(line.width == 400 && line.height == 200, "the inked image keeps its 400x200 size, got \(line.width)x\(line.height)")
        for (x, y) in [(150, 99), (150, 100), (101, 100), (199, 99)] {
            expect(near(rgb(line, x, y), red, within: 2), "a stroke from 300,250 to 500,250 colours pixel \(x),\(y) \(red), got \(rgb(line, x, y))")
        }
        for (x, y) in [(150, 97), (150, 102), (95, 100), (205, 100)] {
            expect(rgb(line, x, y) == paper, "pixel \(x),\(y) stays white, got \(rgb(line, x, y))")
        }
        let edge = rgb(line, 150, 98)
        expect(edge[0] >= 253 && (120...185).contains(edge[1]), "at 0.5 px per point the line is 3 px, not 2: row 98 is half red, got \(edge)")

        let top = Ink([Stroke(CGPoint(x: 300, y: 440), [CGPoint(x: 500, y: 440)])]).composited(onto: blank, appKitFrame: frame)
        expect(near(rgb(top, 150, 4), red, within: 2) && near(rgb(top, 150, 5), red, within: 2),
               "a stroke at y 440 colours rows 4 and 5 from the top, got \(rgb(top, 150, 4)) and \(rgb(top, 150, 5))")
        expect(rgb(top, 150, 194) == paper && rgb(top, 150, 195) == paper, "and not rows 194 and 195, so the y axis is flipped once")

        let away = Ink([Stroke(CGPoint(x: 2000, y: 250), [CGPoint(x: 2100, y: 250)])])
        expect(away.composited(onto: blank, appKitFrame: frame) === blank, "ink off the display returns the same image")
        expect(away.touching(frame).isEmpty, "ink off the display touches nothing")
        let mixed = Ink([Stroke(CGPoint(x: 2000, y: 250)), Stroke(CGPoint(x: 300, y: 250))])
        expect(mixed.touching(frame) == Ink([Stroke(CGPoint(x: 300, y: 250))]), "touching keeps only the stroke on the display, got \(mixed.touching(frame))")
        let grazing = Ink([Stroke(CGPoint(x: 902, y: 250))])
        expect(grazing.touching(frame).strokes.count == 1, "a dot 2 pt past the right edge still touches, its 3 px cap reaches in")

        let dot = Ink([Stroke(CGPoint(x: 50, y: 50))]).composited(onto: white(400, 200), appKitFrame: CGRect(x: 0, y: 0, width: 400, height: 200))
        expect(near(rgb(dot, 49, 149), red, within: 2) && near(rgb(dot, 50, 150), red, within: 2),
               "a one-point stroke at 50,50 draws a dot over pixels 49,149 and 50,150, got \(rgb(dot, 49, 149)) and \(rgb(dot, 50, 150))")
        expect(rgb(dot, 54, 150) == paper && rgb(dot, 50, 145) == paper, "the dot is 4 px across, pixels 54,150 and 50,145 stay white")

        let full = CGRect(x: 0, y: 0, width: 400, height: 200)
        let round = Ink([Stroke(CGPoint(x: 100, y: 100), [CGPoint(x: 300, y: 100)])]).composited(onto: white(400, 200), appKitFrame: full)
        let back = Screenshot(encoding: round, display: 1, appKitFrame: full, cursor: .zero).flatMap { decoded($0.jpeg) }
        let sample = back.map { rgb($0, 200, 99) } ?? []
        expect(near(sample, red, within: 10), "a 4 px line survives the JPEG at pixel 200,99 as \(red) within 10, got \(sample)")

        let builtIn = Screenshot(encoding: solid(1280, 832), display: 1, appKitFrame: builtInFrame, cursor: .zero)!
        let plane = Ink.Plane(frame: builtInFrame, size: CGSize(width: 1280, height: 832))
        for (x, y) in [(0, 0), (211, 12), (640, 416), (1279, 831)] {
            let back = plane.point(builtIn.appKitCentre(ofPixelX: x, y: y))
            expect(abs(back.x - (Double(x) + 0.5)) <= 1e-9 && abs(back.y - (Double(y) + 0.5)) <= 1e-9,
                   "the plane inverts appKitCentre at pixel \(x),\(y), got \(back.x),\(back.y)")
        }
        let widths = [
            ("1920x1080 shrunk to 1280x720", Ink.Plane(frame: mainFrame, size: CGSize(width: 1280, height: 720)).lineWidth, 3.0),
            ("1710x1112 shrunk to 1280x832", plane.lineWidth, 3.0),
            ("an overlay at 1 unit per point", Ink.Plane(frame: builtInFrame, size: builtInFrame.size).lineWidth, 4.0),
            ("640x400 at 2x", Ink.Plane(frame: CGRect(x: 0, y: 0, width: 640, height: 400), size: CGSize(width: 1280, height: 800)).lineWidth, 8.0),
        ]
        for (name, got, want) in widths {
            expect(got == want, "the line on \(name) is \(want) units wide, got \(got)")
        }
    }

    static let backdropRect = CGRect(x: 180, y: 180, width: 400, height: 400)
    static let ownRect = CGRect(x: 300, y: 300, width: 160, height: 160)

    @MainActor
    static func solidWindow(_ color: NSColor, _ rect: CGRect, on screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.backgroundColor = color
        window.isOpaque = true
        window.hasShadow = false
        window.level = .floating
        window.orderFrontRegardless()
        window.display()
        return window
    }

    @MainActor
    static func backdrop() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        _ = solidWindow(.green, backdropRect, on: NSScreen.screens[0])
        try? await Task.sleep(for: .seconds(10))
        exit(0)
    }

    static func fractions(of image: CGImage, in crop: CGRect) -> (magenta: Double, green: Double) {
        let context = context(image.width, image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var (magenta, green, total) = (0, 0, 0)
        for y in Int(crop.minY)..<Int(crop.maxY) {
            for x in Int(crop.minX)..<Int(crop.maxX) {
                let offset = y * context.bytesPerRow + x * 4
                let (r, g, b) = (bytes[offset], bytes[offset + 1], bytes[offset + 2])
                if r > 200, g < 60, b > 200 { magenta += 1 }
                if r < 60, g > 180, b < 60 { green += 1 }
                total += 1
            }
        }
        return (Double(magenta) / Double(total), Double(green) / Double(total))
    }

    @MainActor
    static func live() async {
        print("live")
        NSApplication.shared.setActivationPolicy(.accessory)
        let child = Process()
        child.executableURL = Bundle.main.executableURL!
        child.arguments = ["--backdrop"]
        do {
            try child.run()
        } catch {
            print("  FAIL could not launch the backdrop child, \(error)")
            exit(1)
        }
        func finish(_ window: NSWindow?) -> Never {
            window?.orderOut(nil)
            child.terminate()
            exit(failures == 0 ? 0 : 1)
        }
        var appeared = false
        for _ in 0..<50 where !appeared {
            let listed = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            appeared = listed.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == child.processIdentifier }
            if !appeared { try? await Task.sleep(for: .milliseconds(100)) }
        }
        guard appeared else {
            expect(false, "the backdrop child's window is on screen within 5 s")
            finish(nil)
        }
        let main = NSScreen.screens[0]
        let own = solidWindow(.magenta, ownRect, on: main)
        try? await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        let mouseBefore = NSEvent.mouseLocation
        let shots: [Screenshot]
        do {
            shots = try await Screenshot.everyDisplay()
        } catch {
            if error == .noAccess {
                print("  FAIL the terminal has no Screen Recording grant")
            } else {
                print("  FAIL \(error.logFields)")
            }
            finish(own)
        }
        let elapsed = started.duration(to: .now) / .milliseconds(1)
        let screens = NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { (CGDirectDisplayID($0.uint32Value), screen) }
        }
        expect(Set(shots.map(\.display)) == Set(screens.map(\.0)), "the displays are NSScreen's, \(shots.map(\.display)) against \(screens.map(\.0))")
        expect(shots.count == screens.count, "one screenshot per display, got \(shots.count) for \(screens.count)")
        for shot in shots {
            guard let screen = screens.first(where: { $0.0 == shot.display })?.1 else { continue }
            let longest = max(screen.frame.width, screen.frame.height)
            let shortest = min(screen.frame.width, screen.frame.height)
            let expected = min(1280, (longest * screen.backingScaleFactor).rounded())
            let (pixelsLong, pixelsShort) = (max(shot.pixels.width, shot.pixels.height), min(shot.pixels.width, shot.pixels.height))
            expect(shot.appKitFrame == screen.frame, "display \(shot.display) frame is NSScreen's, got \(shot.appKitFrame) for \(screen.frame)")
            expect(Double(pixelsLong) == expected, "display \(shot.display) longer side is \(Int(expected)), got \(pixelsLong)")
            expect(
                abs(Double(pixelsShort) - Double(pixelsLong) * shortest / longest) <= 1,
                "display \(shot.display) keeps the aspect of \(Int(screen.frame.width))x\(Int(screen.frame.height)), got \(shot.pixels.width)x\(shot.pixels.height)"
            )
            let back = decoded(shot.jpeg)
            expect(back?.width == shot.pixels.width && back?.height == shot.pixels.height, "display \(shot.display) JPEG decodes at its own pixels, got \(back?.width ?? 0)x\(back?.height ?? 0)")
            expect(luminanceQuantizers(shot.jpeg) == pinned, "display \(shot.display) is encoded at quality 0.8, got \(luminanceQuantizers(shot.jpeg))")
            expect(back.map(isFlat) == false, "display \(shot.display) is not one flat colour")
            print("  info display=\(shot.display) pixels=\(shot.pixels.width)x\(shot.pixels.height) points=\(Int(shot.appKitFrame.width))x\(Int(shot.appKitFrame.height)) bytes=\(shot.jpeg.count)")
        }
        let mouseAfter = NSEvent.mouseLocation
        let screenUnder = { (mouse: CGPoint) in screens.first { NSMouseInRect(mouse, $0.1.frame, false) }?.0 }
        if let under = screenUnder(mouseBefore), screenUnder(mouseAfter) == under {
            expect(shots.first?.display == under, "the first screenshot is the display under the cursor \(under), got \(String(describing: shots.first?.display))")
            expect(shots.first?.holdsCursor == true, "the first screenshot holds the cursor")
            expect(shots.dropFirst().allSatisfy { !$0.holdsCursor }, "no other screenshot holds the cursor")
        } else {
            print("  skip the cursor went from \(mouseBefore) to \(mouseAfter) during the capture, not resting on one screen")
        }
        for (index, shot) in shots.enumerated() {
            print("  info \(shot.label(number: index + 1, of: shots.count))")
        }
        print("  info captured displays=\(shots.count) ms=\(Int(elapsed.rounded()))")
        let mainID = (main.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
        if let shot = shots.first(where: { $0.display == mainID }), let image = decoded(shot.jpeg) {
            let k = Double(shot.pixels.width) / shot.appKitFrame.width
            let inner = ownRect.insetBy(dx: 20, dy: 20)
            let crop = CGRect(
                x: inner.minX * k, y: (main.frame.height - inner.maxY) * k,
                width: inner.width * k, height: inner.height * k
            )
            let seen = fractions(of: image, in: crop)
            expect(seen.magenta < 0.01, "the check's own window is left out, magenta fraction \(String(format: "%.3f", seen.magenta))")
            expect(seen.green > 0.99, "another process's window still shows where the own window was, green fraction \(String(format: "%.3f", seen.green))")
        } else {
            expect(false, "the screenshot of the main display \(String(describing: mainID)) decodes")
        }
        finish(own)
    }

    static let markerFractions = [(0.10, 0.15), (0.80, 0.30), (0.35, 0.85), (0.60, 0.55), (0.92, 0.90)]
    static let markerTolerancePixels = 2.0

    @MainActor
    static func markers() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        var windows: [NSWindow] = []
        func borderless(_ color: NSColor, _ frame: CGRect) -> NSWindow {
            let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = color
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.animationBehavior = .none
            window.level = .screenSaver
            windows.append(window)
            return window
        }
        var centres: [CGPoint] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            borderless(NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1), frame).orderFrontRegardless()
            for (fx, fy) in markerFractions {
                let marker = borderless(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGRect(
                    x: (frame.minX + fx * frame.width).rounded() - 20, y: (frame.minY + fy * frame.height).rounded() - 20, width: 40, height: 40
                ))
                marker.orderFrontRegardless()
                marker.display()
                centres.append(CGPoint(x: marker.frame.midX, y: marker.frame.midY))
            }
        }
        for centre in centres { print("marker \(centre.x) \(centre.y)") }
        print("ready")
        fflush(stdout)
        try? await Task.sleep(for: .seconds(15))
        exit(0)
    }

    static func redCentroids(_ image: CGImage) -> [CGPoint] {
        let (width, height) = (image.width, image.height)
        let context = context(width, height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        func isRed(_ x: Int, _ y: Int) -> Bool {
            let offset = y * context.bytesPerRow + x * 4
            return bytes[offset] > 180 && bytes[offset + 1] < 80 && bytes[offset + 2] < 80
        }
        var seen = Set<Int>()
        var found: [CGPoint] = []
        for y in 0..<height {
            for x in 0..<width where isRed(x, y) && !seen.contains(y * width + x) {
                var stack = [(x, y)]
                var (count, sumX, sumY) = (0, 0, 0)
                seen.insert(y * width + x)
                while let (cx, cy) = stack.popLast() {
                    count += 1
                    sumX += cx
                    sumY += cy
                    for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
                    where nx >= 0 && ny >= 0 && nx < width && ny < height && isRed(nx, ny) && !seen.contains(ny * width + nx) {
                        seen.insert(ny * width + nx)
                        stack.append((nx, ny))
                    }
                }
                if count >= 20 { found.append(CGPoint(x: Double(sumX) / Double(count), y: Double(sumY) / Double(count))) }
            }
        }
        return found
    }

    @MainActor
    static func point() async {
        print("point live")
        NSApplication.shared.setActivationPolicy(.accessory)
        let child = Process()
        child.executableURL = Bundle.main.executableURL!
        child.arguments = ["--markers"]
        let pipe = Pipe()
        child.standardOutput = pipe
        do {
            try child.run()
        } catch {
            print("  FAIL could not launch the markers child, \(error)")
            exit(1)
        }
        func finish() -> Never {
            child.terminate()
            exit(failures == 0 ? 0 : 1)
        }
        var truth: [CGPoint] = []
        var ready = false
        var buffer = ""
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready, ContinuousClock.now < deadline {
            let chunk = await Task.detached { pipe.fileHandleForReading.availableData }.value
            if chunk.isEmpty { break }
            buffer += String(decoding: chunk, as: UTF8.self)
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer.removeSubrange(...newline)
                let words = line.split(separator: " ")
                if words.first == "marker", words.count == 3, let x = Double(words[1]), let y = Double(words[2]) {
                    truth.append(CGPoint(x: x, y: y))
                } else if line == "ready" {
                    ready = true
                }
            }
        }
        guard ready else {
            expect(false, "the markers child reports ready within 10 s")
            finish()
        }
        try? await Task.sleep(for: .milliseconds(500))
        let shots: [Screenshot]
        do {
            shots = try await Screenshot.everyDisplay()
        } catch {
            print("  FAIL \(error == .noAccess ? "the terminal has no Screen Recording grant" : error.logFields)")
            finish()
        }
        print("  info displays=\(shots.count)")
        if shots.count < 2 {
            print("  skip the second display's path was covered offline only")
        }
        for shot in shots {
            guard let image = decoded(shot.jpeg) else {
                expect(false, "display \(shot.display) JPEG decodes")
                continue
            }
            let found = redCentroids(image).map { shot.appKitCentre(ofPixelX: Int($0.x.rounded()), y: Int($0.y.rounded())) }
            expect(found.count == markerFractions.count, "display \(shot.display) shows \(markerFractions.count) red markers, got \(found.count)")
            let pixel = shot.appKitFrame.width / Double(shot.pixels.width)
            for expected in truth where NSMouseInRect(expected, shot.appKitFrame, false) {
                guard let nearest = found.min(by: { hypot($0.x - expected.x, $0.y - expected.y) < hypot($1.x - expected.x, $1.y - expected.y) }) else { continue }
                let distance = hypot(nearest.x - expected.x, nearest.y - expected.y)
                expect(
                    distance <= markerTolerancePixels * pixel,
                    "display \(shot.display) marker at (\(expected.x), \(expected.y)) is found at (\(String(format: "%.1f", nearest.x)), \(String(format: "%.1f", nearest.y))), \(String(format: "%.2f", distance)) pt or \(String(format: "%.2f", distance / pixel)) screenshot pixels away"
                )
            }
        }
        finish()
    }
}
