import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "screenshot")

nonisolated struct Screenshot: Equatable, Sendable {
    struct Pixels: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    enum Failure: Error, Equatable, Sendable {
        case noAccess
        case listing(String)

        var logFields: String {
            switch self {
            case .noAccess: "reason=noAccess"
            case .listing(let detail): "reason=listing detail=\(detail)"
            }
        }
    }

    let display: CGDirectDisplayID
    let appKitFrame: CGRect
    let pixels: Pixels
    let holdsCursor: Bool
    let jpeg: Data

    init?(encoding image: CGImage, display: CGDirectDisplayID, appKitFrame: CGRect, cursor: CGPoint) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.display = display
        pixels = Pixels(width: image.width, height: image.height)
        self.appKitFrame = appKitFrame
        // The mouse on a display's top pixel row reads y == appKitFrame.maxY, which half-open CGRect.contains would drop.
        holdsCursor = NSMouseInRect(cursor, appKitFrame, false)
        jpeg = data as Data
    }

    func label(number: Int, of count: Int) -> String {
        let cursor = holdsCursor ? "The cursor is on this screen." : "The cursor is not on this screen."
        return "Screen \(number) of \(count). \(cursor) This image is \(pixels.width)x\(pixels.height) pixels."
    }

    static func cursorFirst(_ shots: [Screenshot]) -> [Screenshot] {
        shots.filter(\.holdsCursor) + shots.filter { !$0.holdsCursor }
    }

    static func appKitFrame(of displayFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: displayFrame.minX, y: primaryHeight - displayFrame.maxY, width: displayFrame.width, height: displayFrame.height)
    }

    @concurrent static func everyDisplay() async throws(Failure) -> [Screenshot] {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            logger.notice("screenshots failed \(Failure.noAccess.logFields, privacy: .public)")
            throw .noAccess
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch let error as SCStreamError where error.code == .userDeclined {
            logger.notice("screenshots failed \(Failure.noAccess.logFields, privacy: .public)")
            throw .noAccess
        } catch {
            let failure = Failure.listing(error.localizedDescription)
            logger.error("screenshots failed \(failure.logFields, privacy: .public)")
            throw failure
        }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let cursor = NSEvent.mouseLocation
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        var shots: [Screenshot] = []
        for display in content.displays {
            let started = ContinuousClock.now
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let points = CGSize(width: display.width, height: display.height)
            let size = Pixels(fitting: points, scale: CGFloat(SCShareableContent.info(for: filter).pointPixelScale))
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                logger.error("screenshot failed display=\(display.displayID) reason=capture detail=\(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let shot = Screenshot(
                encoding: image, display: display.displayID,
                appKitFrame: appKitFrame(of: display.frame, primaryHeight: primaryHeight), cursor: cursor
            ) else {
                logger.error("screenshot failed display=\(display.displayID) reason=encode")
                continue
            }
            let elapsed = started.duration(to: .now) / .milliseconds(1)
            logger.notice("""
                screenshot taken display=\(shot.display) pixels=\(shot.pixels.width)x\(shot.pixels.height) \
                points=\(Int(shot.appKitFrame.width))x\(Int(shot.appKitFrame.height)) cursor=\(shot.holdsCursor ? "yes" : "no", privacy: .public) self=\(own.isEmpty ? "offscreen" : "hidden", privacy: .public) bytes=\(shot.jpeg.count) ms=\(Int(elapsed.rounded()))
                """)
            shots.append(shot)
        }
        let ordered = cursorFirst(shots)
        for (index, shot) in ordered.enumerated() {
            logger.notice("screenshot labelled display=\(shot.display) label=\(shot.label(number: index + 1, of: ordered.count), privacy: .public)")
        }
        return ordered
    }
}

extension Screenshot.Pixels {
    nonisolated init(fitting points: CGSize, scale: CGFloat) {
        let native = CGSize(width: points.width * scale, height: points.height * scale)
        let longest = max(native.width, native.height)
        let factor = min(1, 1280 / longest)
        self.init(
            width: max(1, Int((native.width * factor).rounded())),
            height: max(1, Int((native.height * factor).rounded()))
        )
    }
}
