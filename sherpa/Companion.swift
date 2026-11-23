import AppKit
import ApplicationServices
import Observation
import SwiftUI
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "companion")

nonisolated struct Flight: Equatable, Sendable {
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint
    let duration: Duration

    init(from: CGPoint, to: CGPoint) {
        let distance = hypot(to.x - from.x, to.y - from.y)
        let lift = min(distance * 0.2, 80)
        self.from = from
        self.to = to
        control = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + lift)
        duration = .seconds(min(max(distance / 1500, 0.5), 1.2))
    }

    func position(after elapsed: Duration) -> CGPoint {
        let s = eased(elapsed)
        let (a, b, c) = ((1 - s) * (1 - s), 2 * (1 - s) * s, s * s)
        return CGPoint(x: a * from.x + b * control.x + c * to.x, y: a * from.y + b * control.y + c * to.y)
    }

    func heading(after elapsed: Duration) -> Angle {
        let s = eased(elapsed)
        return Angle(clockwiseFromUpTo: CGVector(
            dx: 2 * (1 - s) * (control.x - from.x) + 2 * s * (to.x - control.x),
            dy: 2 * (1 - s) * (control.y - from.y) + 2 * s * (to.y - control.y)
        ))
    }

    private func eased(_ elapsed: Duration) -> Double {
        let progress = min(max(elapsed / duration, 0), 1)
        return progress * progress * (3 - 2 * progress)
    }
}

nonisolated struct Callout: Equatable, Sendable {
    /// In AppKit global space, like `bounds`. An arrow runs from its `from` to the callout's bounds.
    enum Mark: Equatable, Sendable {
        case ring
        case underline
        case arrow(from: CGRect)
    }

    let point: CGPoint
    let label: String
    /// The thing's bounds in AppKit global space. Nil when Claude named a single pixel.
    let bounds: CGRect?
    var mark = Mark.ring
}

nonisolated struct Bubble: Equatable, Sendable {
    enum Side: String, Sendable { case right, left }

    let label: String
    let side: Side
    let frame: CGRect
    let appeared: Date

    static var font: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    static let padding = CGSize(width: 8, height: 4)
    static let maxWidth: CGFloat = 240
    private static let gap: CGFloat = 10
    private static let drop: CGFloat = 18

    init(label: String, beside glyph: CGPoint, on screens: [CGRect], appeared: Date) {
        let text = (label as NSString).size(withAttributes: [.font: Self.font])
        let size = CGSize(width: min(ceil(text.width) + 2 * Self.padding.width, Self.maxWidth),
                          height: ceil(text.height) + 2 * Self.padding.height)
        let screen = screens.first { NSMouseInRect(glyph, $0, false) }
        side = glyph.x + Self.gap + size.width <= (screen?.maxX ?? .infinity) - Companion.margin ? .right : .left
        var y = glyph.y - Self.drop - size.height / 2
        if let screen { y = min(max(y, screen.minY + Companion.margin), screen.maxY - Companion.margin - size.height) }
        frame = CGRect(origin: CGPoint(x: side == .right ? glyph.x + Self.gap : glyph.x - Self.gap - size.width, y: y), size: size)
        self.label = label
        self.appeared = appeared
    }

    static func reveal(_ index: Int) -> Duration {
        .milliseconds((0..<index).reduce(0) { $0 + 30 + (17 * $1) % 31 })
    }

    func revealed(after elapsed: Duration) -> Int {
        (0..<label.count).prefix { Self.reveal($0) <= elapsed }.count
    }

    var typing: Duration { Self.reveal(max(label.count - 1, 0)) }
}

nonisolated extension Angle {
    init(clockwiseFromUpTo direction: CGVector) {
        self = .radians(atan2(direction.dx, direction.dy))
    }
}

@MainActor
@Observable
final class Companion {
    /// The glyph's centre in AppKit global coordinates: bottom-left origin of the primary
    /// display, y up. The same space as NSEvent.mouseLocation and NSScreen.frame.
    private(set) var position: CGPoint
    private(set) var heading = Companion.restingHeading

    /// From the pointer's hotspot to the glyph's centre: right and below, in AppKit y-up terms.
    static let offset = CGVector(dx: 35, dy: -25)
    nonisolated static let margin: CGFloat = 12
    /// The apex is drawn pointing up. Turn it to face back along the offset, at the hotspot:
    /// local offset is (35, 25) down-right, so the hotspot lies at atan2(-35, 25), about -54 degrees.
    static let restingHeading = Angle(clockwiseFromUpTo: CGVector(dx: -offset.dx, dy: -offset.dy))
    private static let follow = Animation.spring(response: 0.2, dampingFraction: 0.6)
    private static let pop = Animation.spring(response: 0.4, dampingFraction: 0.6)
    private static let fade = Animation.easeOut(duration: 0.3)
    private static let deadZone: CGFloat = 24
    private static let smallestRinged: CGFloat = 4

    /// True once the pointer has sat still for `restAfter`, five minutes outside tests; the glyph
    /// fades out until the next activity.
    private(set) var resting = false

    private struct Leg {
        let flight: Flight
        let started: ContinuousClock.Instant
        let timer: Timer
    }

    private enum Motion {
        case following
        case outbound(Leg, Callout)
        case pausing(Bubble, ring: CGRect?, releasable: ContinuousClock.Instant, deadline: Task<Void, Never>)
        case returning(Leg, anchor: CGPoint)
    }

    private var motion = Motion.following {
        didSet {
            switch oldValue {
            case .outbound(let leg, _), .returning(let leg, _): leg.timer.invalidate()
            case .pausing(_, _, _, let deadline): deadline.cancel()
            case .following: break
            }
        }
    }
    @ObservationIgnored private var callout: Callout?
    let hold: Duration

    var bubble: Bubble? {
        if case .pausing(let bubble, _, _, _) = motion { bubble } else { nil }
    }

    /// The bounds of the thing the companion points at, in AppKit global space, while it pauses there.
    var ring: CGRect? {
        if case .pausing(_, let ring, _, _) = motion { ring } else { nil }
    }

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
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var restWatch: Task<Void, Never>?
    let restAfter: Duration

    init(hold: Duration = .seconds(3)) {
        self.hold = hold
        var restAfter = Duration.seconds(300)
        #if DEBUG
        if let seconds = UserDefaults.standard.string(forKey: "CompanionRestSeconds").flatMap(Double.init) {
            restAfter = .seconds(seconds)
        }
        #endif
        self.restAfter = restAfter
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
        watchForRest()
    }

    /// Where the glyph's centre goes for a pointer at `pointer`: the offset, clamped inside the
    /// screen that holds the pointer so the glyph never hangs off an edge or into a gap between
    /// displays. NSMouseInRect, not CGRect.contains: the pointer on a screen's top row reads
    /// y == frame.maxY. No screen holds the pointer only mid-reconfiguration; then no clamp.
    static func position(following pointer: CGPoint, on screens: [CGRect]) -> CGPoint {
        position(pointingAt: pointer, on: screens.first { NSMouseInRect(pointer, $0, false) })
    }

    /// Where the glyph's centre lands for a callout: pointing at the bottom-right corner of the
    /// thing's bounds, so it sits beside the thing and not on it, or at the point when there are no
    /// bounds. Clamped inside the screen that holds the point, since a corner on a screen's right or
    /// bottom edge lies outside that screen.
    static func landing(for callout: Callout, on screens: [CGRect]) -> CGPoint {
        let tip = callout.bounds.map { CGPoint(x: $0.maxX, y: $0.minY) } ?? callout.point
        return position(pointingAt: tip, on: screens.first { NSMouseInRect(callout.point, $0, false) })
    }

    private static func position(pointingAt hotspot: CGPoint, on screen: CGRect?) -> CGPoint {
        let spot = CGPoint(x: hotspot.x + offset.dx, y: hotspot.y + offset.dy)
        guard let screen else { return spot }
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

    func followPointer() {
        if case .returning(_, let anchor) = motion {
            let pointer = NSEvent.mouseLocation
            let moved = hypot(pointer.x - anchor.x, pointer.y - anchor.y)
            guard moved > Self.deadZone else { return }
            withAnimation(.easeOut(duration: 0.2)) { heading = Self.resting(nearest: heading) }
            logger.notice("companion cancelled at=\(Self.field(self.position), privacy: .public) moved=\(Int(moved.rounded()))")
            return follow()
        }
        guard case .following = motion else { return }
        let next = Self.position(following: NSEvent.mouseLocation, on: NSScreen.screens.map(\.frame))
        if next == position { return }
        withAnimation(Self.follow) { position = next }
        wake()
    }

    func point(at callout: Callout?) {
        if callout == self.callout { return }
        self.callout = callout
        guard let callout else { return releaseIfDue() }
        let flight = Flight(from: position, to: Self.landing(for: callout, on: NSScreen.screens.map(\.frame)))
        wake()
        guard let leg = takeOff(flight) else { return land(flight, at: callout) }
        withAnimation(Self.fade) { motion = .outbound(leg, callout) }
        logger.notice("""
            companion flying from=\(Self.field(flight.from), privacy: .public) to=\(Self.field(flight.to), privacy: .public) \
            ms=\(Self.milliseconds(flight.duration))
            """)
    }

    private func releaseIfDue() {
        guard case .pausing(let bubble, _, let releasable, _) = motion, callout == nil, ContinuousClock.now >= releasable else { return }
        let pointer = NSEvent.mouseLocation
        let flight = Flight(from: position, to: Self.position(following: pointer, on: NSScreen.screens.map(\.frame)))
        logger.notice("""
            companion returning from=\(Self.field(flight.from), privacy: .public) to=\(Self.field(flight.to), privacy: .public) \
            ms=\(Self.milliseconds(flight.duration)) paused=\(Int((Date.now.timeIntervalSince(bubble.appeared) * 1000).rounded()))
            """)
        guard let leg = takeOff(flight) else { return withAnimation(Self.fade) { land(flight, at: nil) } }
        withAnimation(Self.fade) { motion = .returning(leg, anchor: pointer) }
    }

    private func takeOff(_ flight: Flight) -> Leg? {
        if hypot(flight.to.x - flight.from.x, flight.to.y - flight.from.y) < 1 { return nil }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return Leg(flight: flight, started: .now, timer: timer)
    }

    private func tick() {
        let (leg, callout): (Leg, Callout?)
        switch motion {
        case .outbound(let outbound, let to): (leg, callout) = (outbound, to)
        case .returning(let returning, _): (leg, callout) = (returning, nil)
        case .following, .pausing: return
        }
        let elapsed = leg.started.duration(to: .now)
        position = leg.flight.position(after: elapsed)
        heading = leg.flight.heading(after: elapsed)
        if elapsed >= leg.flight.duration { land(leg.flight, at: callout) }
    }

    private func land(_ flight: Flight, at callout: Callout?) {
        position = flight.to
        withAnimation(.easeOut(duration: 0.2)) { heading = Self.resting(nearest: heading) }
        logger.notice("companion landed at=\(Self.field(flight.to), privacy: .public)")
        guard let callout else { return follow() }
        let bubble = Bubble(label: callout.label, beside: flight.to, on: NSScreen.screens.map(\.frame), appeared: .now)
        let ring = callout.bounds.flatMap { min($0.width, $0.height) < Self.smallestRinged ? nil : $0 }
        let releasable = ContinuousClock.now + bubble.typing + hold
        let deadline = Task { [weak self] in
            while ContinuousClock.now < releasable {
                guard (try? await Task.sleep(until: releasable, clock: .continuous)) != nil else { return }
            }
            self?.releaseIfDue()
        }
        withAnimation(Self.pop) { motion = .pausing(bubble, ring: ring, releasable: releasable, deadline: deadline) }
        logger.notice("""
            companion pausing chars=\(bubble.label.count) typed=\(Self.milliseconds(bubble.typing)) \
            side=\(bubble.side.rawValue, privacy: .public) bubble=\(Self.field(bubble.frame), privacy: .public) \
            ring=\(ring.map { Self.field($0) } ?? "none", privacy: .public)
            """)
    }

    private static func resting(nearest heading: Angle) -> Angle {
        let turns = ((heading.radians - restingHeading.radians) / (2 * .pi)).rounded()
        return .radians(restingHeading.radians + turns * 2 * .pi)
    }

    private func follow() {
        motion = .following
        logger.notice("companion following")
        followPointer()
    }

    private static func field(_ point: CGPoint) -> String {
        String(format: "%.1f,%.1f", point.x, point.y)
    }

    private static func field(_ rect: CGRect) -> String {
        String(format: "%.1f,%.1f,%.1f,%.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    /// Voice activity counts as activity, so a hold wakes a resting companion and the rest time
    /// restarts when Sherpa goes back to idle.
    func wake() {
        lastActivity = .now
        if resting {
            withAnimation(.easeOut(duration: 0.2)) { resting = false }
            logger.notice("companion woke")
        }
        watchForRest()
    }

    private func watchForRest() {
        if restWatch != nil { return }
        restWatch = Task { [weak self] in
            while let self {
                let due = lastActivity + restAfter
                if .now >= due {
                    withAnimation(.easeIn(duration: 1)) { self.resting = true }
                    logger.notice("companion resting")
                    restWatch = nil
                    return
                }
                try? await Task.sleep(until: due, clock: .continuous)
            }
        }
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
