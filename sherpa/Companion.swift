import AppKit
import ApplicationServices
import Observation
import SwiftUI
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "companion")

@MainActor
@Observable
final class Companion {
    /// The glyph's centre in AppKit global coordinates: bottom-left origin of the primary
    /// display, y up. The same space as NSEvent.mouseLocation and NSScreen.frame.
    private(set) var position: CGPoint

    /// From the pointer's hotspot to the glyph's centre: right and below, in AppKit y-up terms.
    static let offset = CGVector(dx: 35, dy: -25)
    static let margin: CGFloat = 12
    private static let follow = Animation.spring(response: 0.2, dampingFraction: 0.6)

    // A mouse tap needs the Accessibility grant (an ungranted app gets a non-nil tap that reads
    // tapIsEnabled false), so the companion polls until the grant.
    private enum Feed {
        case polling(Timer)
        case tapping(CFMachPort)
    }

    private static let mouseEvents: CGEventMask = [
        CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ].reduce(0) { $0 | 1 << $1.rawValue }

    @ObservationIgnored private var feed: Feed?

    init() {
        position = Self.position(following: NSEvent.mouseLocation, on: NSScreen.screens.map(\.frame))
    }

    func start() async {
        if feed != nil { return }
        // Hotkey owns the Accessibility prompt.
        if !AXIsProcessTrusted() {
            feed = .polling(schedulePoll())
            logger.notice("companion polling reason=untrusted")
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let port = makeTap() else {
            logger.error("companion polling reason=tapFailed")
            if feed == nil { feed = .polling(schedulePoll()) }
            return
        }
        if case .polling(let poll) = feed { poll.invalidate() }
        feed = .tapping(port)
        logger.notice("companion tapping")
        followPointer()
    }

    /// Where the glyph's centre goes for a pointer at `pointer`: the offset, clamped inside the
    /// screen that holds the pointer so the glyph never hangs off an edge or into a gap between
    /// displays. NSMouseInRect, not CGRect.contains: the pointer on a screen's top row reads
    /// y == frame.maxY. No screen holds the pointer only mid-reconfiguration; then no clamp.
    static func position(following pointer: CGPoint, on screens: [CGRect]) -> CGPoint {
        let spot = CGPoint(x: pointer.x + offset.dx, y: pointer.y + offset.dy)
        guard let screen = screens.first(where: { NSMouseInRect(pointer, $0, false) }) else { return spot }
        return CGPoint(
            x: min(max(spot.x, screen.minX + margin), screen.maxX - margin),
            y: min(max(spot.y, screen.minY + margin), screen.maxY - margin)
        )
    }

    /// AppKit global (y up) to the SwiftUI space of the overlay that covers `screenFrame`
    /// (top-left origin, y down).
    static func local(_ point: CGPoint, in screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }

    fileprivate func followPointer() {
        let next = Self.position(following: NSEvent.mouseLocation, on: NSScreen.screens.map(\.frame))
        if next == position { return }
        withAnimation(Self.follow) { position = next }
    }

    fileprivate func reenable(after type: CGEventType) {
        guard case .tapping(let port) = feed else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        logger.notice("companion reenabled cause=\(type == .tapDisabledByTimeout ? "timeout" : "input", privacy: .public)")
        // On macOS 27.2 the notice replaces the next event, so a move may have been dropped.
        followPointer()
    }

    private func makeTap() -> CFMachPort? {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.mouseEvents,
            callback: companionCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        guard CGEvent.tapIsEnabled(tap: port) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        return port
    }

    private func schedulePoll() -> Timer {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

private nonisolated func companionCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let companion = Unmanaged<Companion>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated {
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput: companion.reenable(after: type)
            default: companion.followPointer()
            }
        }
    }
    return Unmanaged.passUnretained(event)
}
