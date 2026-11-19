import ApplicationServices
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "ink")

private let penEvents = CGEventMask(
    1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.leftMouseUp.rawValue | 1 << CGEventType.leftMouseDragged.rawValue
)

/// While ctrl+option is down, an active tap takes the left button: the app under the pointer gets
/// none of a press it takes, and the drags go on as mouse moves. The tap exists only while the
/// chord is down or a press it took is still down.
final class Pen {
    nonisolated enum Mark: Equatable, Sendable {
        case began(CGPoint)
        case moved(CGPoint)
        case chordUp
    }

    nonisolated struct Hand: Equatable, Sendable {
        enum Button: Equatable, Sendable {
            case free
            case drawing(Trace)
            /// The chord went up mid-stroke. The rest of the press is still taken, so the app never
            /// gets half of one, but no longer drawn, so the overlay shows what the screenshot got.
            case sealed(Trace)
        }

        struct Trace: Equatable, Sendable {
            var points: Int
            let from: CGPoint
            var last: CGPoint
        }

        enum Input: Equatable, Sendable {
            case chord(down: Bool)
            case down(CGPoint, flagged: Bool)
            case dragged(CGPoint)
            case up(CGPoint)
        }

        enum Verdict: Equatable, Sendable {
            case pass
            case swallow
            case asMove
        }

        struct Finished: Equatable, Sendable {
            let points: Int
            let from: CGPoint
            let to: CGPoint
            let sealed: Bool
        }

        struct Outcome: Equatable, Sendable {
            var verdict: Verdict
            var mark: Mark? = nil
            var finished: Finished? = nil
        }

        private(set) var chord = false
        private(set) var button = Button.free

        var wantsTap: Bool { chord || button != .free }

        mutating func handle(_ input: Input) -> Outcome {
            switch input {
            case .chord(down: true):
                chord = true
                return Outcome(verdict: .pass)
            case .chord(down: false):
                guard chord else { return Outcome(verdict: .pass) }
                chord = false
                if case .drawing(let trace) = button { button = .sealed(trace) }
                return Outcome(verdict: .pass, mark: .chordUp)
            case .down(let point, let flagged):
                let lost = finish()
                guard chord else { return Outcome(verdict: .pass, finished: lost) }
                guard flagged else {
                    chord = false
                    return Outcome(verdict: .pass, mark: .chordUp, finished: lost)
                }
                button = .drawing(Trace(points: 1, from: point, last: point))
                return Outcome(verdict: .swallow, mark: .began(point), finished: lost)
            case .dragged(let point):
                switch button {
                case .drawing(var trace):
                    trace.points += 1
                    trace.last = point
                    button = .drawing(trace)
                    return Outcome(verdict: .asMove, mark: .moved(point))
                case .sealed:
                    return Outcome(verdict: .asMove)
                case .free:
                    return Outcome(verdict: .pass)
                }
            case .up:
                guard let finished = finish() else { return Outcome(verdict: .pass) }
                return Outcome(verdict: .swallow, finished: finished)
            }
        }

        private mutating func finish() -> Finished? {
            defer { button = .free }
            return switch button {
            case .free: nil
            case .drawing(let trace): Finished(points: trace.points, from: trace.from, to: trace.last, sealed: false)
            case .sealed(let trace): Finished(points: trace.points, from: trace.from, to: trace.last, sealed: true)
            }
        }
    }

    private struct Tap {
        let port: CFMachPort
        let source: CFRunLoopSource
    }

    private let state: AppState
    private var hand = Hand() {
        didSet { settle() }
    }
    private var tap: Tap?

    init(state: AppState) {
        self.state = state
    }

    func chord(down: Bool) {
        apply(.chord(down: down))
    }

    @discardableResult
    private func apply(_ input: Hand.Input) -> Hand.Verdict {
        let outcome = hand.handle(input)
        if let stroke = outcome.finished {
            logger.notice("""
                ink stroke points=\(stroke.points) \
                from=\(String(format: "%.1f,%.1f", stroke.from.x, stroke.from.y), privacy: .public) \
                to=\(String(format: "%.1f,%.1f", stroke.to.x, stroke.to.y), privacy: .public) \
                sealed=\(stroke.sealed ? "yes" : "no", privacy: .public)
                """)
        }
        if let mark = outcome.mark { state.draw(mark) }
        return outcome.verdict
    }

    /// Teardown waits one turn: settle() can run inside the tap's own callback, which still has to
    /// return its verdict, and a chord pressed again in that turn keeps the tap.
    private func settle() {
        if hand.wantsTap {
            if tap == nil { tap = makeTap() }
        } else if tap != nil {
            Task { [weak self] in self?.closeIfUnwanted() }
        }
    }

    private func closeIfUnwanted() {
        guard !hand.wantsTap, let tap else { return }
        CGEvent.tapEnable(tap: tap.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), tap.source, .commonModes)
        CFMachPortInvalidate(tap.port)
        self.tap = nil
    }

    /// An app without the Accessibility grant gets a tap back that is non-nil but disabled.
    private func makeTap() -> Tap? {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: penEvents,
            callback: penCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("ink pen failed tap=nil")
            return nil
        }
        guard CGEvent.tapIsEnabled(tap: port), let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            logger.error("ink pen failed tap=disabled")
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return Tap(port: port, source: source)
    }

    fileprivate func decide(_ type: CGEventType, at quartz: CGPoint, flags: CGEventFlags) -> Hand.Verdict {
        let point = CGPoint(x: quartz.x, y: CGDisplayBounds(CGMainDisplayID()).height - quartz.y)
        return switch type {
        case .leftMouseDown: apply(.down(point, flagged: flags.holdsChord))
        case .leftMouseDragged: apply(.dragged(point))
        case .leftMouseUp: apply(.up(point))
        default: .pass
        }
    }

    fileprivate func reenable(after type: CGEventType) {
        guard hand.wantsTap, let tap else { return }
        CGEvent.tapEnable(tap: tap.port, enable: true)
        logger.notice("ink pen reenabled cause=\(type == .tapDisabledByTimeout ? "timeout" : "input", privacy: .public)")
    }
}

private nonisolated func penCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let pen = Unmanaged<Pen>.fromOpaque(userInfo).takeUnretainedValue()
    let (location, flags) = (event.location, event.flags)
    let verdict = MainActor.assumeIsolated { () -> Pen.Hand.Verdict in
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            pen.reenable(after: type)
            return .pass
        default:
            return pen.decide(type, at: location, flags: flags)
        }
    }
    switch verdict {
    case .pass:
        return Unmanaged.passUnretained(event)
    case .swallow:
        return nil
    case .asMove:
        event.type = .mouseMoved
        return Unmanaged.passUnretained(event)
    }
}
