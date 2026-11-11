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
        if CommandLine.arguments.contains("--live") {
            await live()
            return
        }
        checkFitting()
        checkEncoding()
        checkFailure()
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
        let points = CGSize(width: 1710, height: 1112)
        let image = gradient(1280, 832)
        guard let shot = Screenshot(encoding: image, display: 7, points: points) else {
            expect(false, "a drawn 1280x832 image encodes")
            return
        }
        expect(shot.pixels == .init(width: 1280, height: 832), "pixels come from the image, got \(shot.pixels)")
        expect(shot.points == points, "points are kept as given, got \(shot.points)")
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
        let flat = Screenshot(encoding: solid(64, 64), display: 1, points: CGSize(width: 64, height: 64))
        expect(flat.flatMap { decoded($0.jpeg) }.map(isFlat) == true, "a solid image decodes as one flat colour")
        let tiny = Screenshot(encoding: gradient(4, 2), display: 1, points: CGSize(width: 1280, height: 640))
        expect(tiny?.pixels == .init(width: 4, height: 2), "a 4x2 image stays 4x2, so encoding never resizes, got \(String(describing: tiny?.pixels))")
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

    @MainActor
    static func live() async {
        print("live")
        let started = ContinuousClock.now
        let shots: [Screenshot]
        do {
            shots = try await Screenshot.everyDisplay()
        } catch {
            if error == .noAccess {
                print("  FAIL the terminal has no Screen Recording grant")
            } else {
                print("  FAIL \(error.logFields)")
            }
            exit(1)
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
            expect(shot.points == screen.frame.size, "display \(shot.display) points are the frame size, got \(shot.points) for \(screen.frame.size)")
            expect(Double(pixelsLong) == expected, "display \(shot.display) longer side is \(Int(expected)), got \(pixelsLong)")
            expect(
                abs(Double(pixelsShort) - Double(pixelsLong) * shortest / longest) <= 1,
                "display \(shot.display) keeps the aspect of \(Int(screen.frame.width))x\(Int(screen.frame.height)), got \(shot.pixels.width)x\(shot.pixels.height)"
            )
            let back = decoded(shot.jpeg)
            expect(back?.width == shot.pixels.width && back?.height == shot.pixels.height, "display \(shot.display) JPEG decodes at its own pixels, got \(back?.width ?? 0)x\(back?.height ?? 0)")
            expect(luminanceQuantizers(shot.jpeg) == pinned, "display \(shot.display) is encoded at quality 0.8, got \(luminanceQuantizers(shot.jpeg))")
            expect(back.map(isFlat) == false, "display \(shot.display) is not one flat colour")
            print("  info display=\(shot.display) pixels=\(shot.pixels.width)x\(shot.pixels.height) points=\(Int(shot.points.width))x\(Int(shot.points.height)) bytes=\(shot.jpeg.count)")
        }
        print("  info captured displays=\(shots.count) ms=\(Int(elapsed.rounded()))")
        exit(failures == 0 ? 0 : 1)
    }
}
