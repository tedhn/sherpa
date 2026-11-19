import ApplicationServices

final class AppState {
    var held: [Bool] = []
    var marks: [Pen.Mark] = []
    func setHeld(_ held: Bool) { self.held.append(held) }
    func draw(_ mark: Pen.Mark) { marks.append(mark) }
}

@main
enum HotkeyStartCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String, _ actual: @autoclosure () -> String = "") {
        print(ok ? "  ok   \(what)" : "  FAIL \(what): \(actual())")
        if !ok { failures += 1 }
    }

    static func main() {
        checkHand()
        Task {
            await run()
            exit(failures == 0 ? 0 : 1)
        }
        CFRunLoopRun()
    }

    static func ownTaps() -> [CGEventTapInformation] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        return taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }
    }

    static func activeTaps() -> [CGEventTapInformation] {
        ownTaps().filter { $0.options == .defaultTap }
    }

    static func checkHand() {
        typealias Outcome = Pen.Hand.Outcome
        typealias Finished = Pen.Hand.Finished
        let (p1, p2, p3) = (CGPoint(x: 100, y: 100), CGPoint(x: 112, y: 100), CGPoint(x: 124, y: 100))
        func describe(_ outcome: Outcome) -> String { "\(outcome)" }

        var hand = Pen.Hand()
        expect(!hand.wantsTap, "a fresh hand wants no tap")
        var got = hand.handle(.chord(down: true))
        expect(got == Outcome(verdict: .pass) && hand.wantsTap, "the chord going down passes and wants the tap", describe(got))
        got = hand.handle(.down(p1, flagged: true))
        expect(got == Outcome(verdict: .swallow, mark: .began(p1)), "a chorded down is swallowed and begins a stroke at 100,100", describe(got))
        got = hand.handle(.dragged(p2))
        expect(got == Outcome(verdict: .asMove, mark: .moved(p2)), "a drag goes on as a move and extends to 112,100", describe(got))
        got = hand.handle(.chord(down: false))
        expect(got == Outcome(verdict: .pass, mark: .chordUp) && hand.wantsTap, "the chord going up mid-stroke releases and keeps the tap", describe(got))
        got = hand.handle(.dragged(p3))
        expect(got == Outcome(verdict: .asMove), "a sealed stroke's drag still goes on as a move, with no mark", describe(got))
        got = hand.handle(.up(p3))
        expect(got == Outcome(verdict: .swallow, finished: Finished(points: 2, from: p1, to: p2, sealed: true)) && !hand.wantsTap,
               "its up is swallowed, finishes 2 points sealed and drops the tap", describe(got))

        hand = Pen.Hand()
        _ = hand.handle(.chord(down: true))
        got = hand.handle(.down(p1, flagged: true))
        got = hand.handle(.up(p1))
        expect(got == Outcome(verdict: .swallow, finished: Finished(points: 1, from: p1, to: p1, sealed: false)) && hand.wantsTap,
               "a plain click under the chord is a one-point stroke and the chord keeps the tap", describe(got))

        hand = Pen.Hand()
        _ = hand.handle(.chord(down: true))
        got = hand.handle(.down(p1, flagged: false))
        expect(got == Outcome(verdict: .pass, mark: .chordUp) && !hand.chord && !hand.wantsTap,
               "a down without the chord's flags passes and clears the stale chord", describe(got))

        hand = Pen.Hand()
        _ = hand.handle(.chord(down: true))
        _ = hand.handle(.down(p1, flagged: true))
        _ = hand.handle(.dragged(p2))
        got = hand.handle(.down(p3, flagged: true))
        expect(got == Outcome(verdict: .swallow, mark: .began(p3), finished: Finished(points: 2, from: p1, to: p2, sealed: false)),
               "a down while drawing finishes the stroke whose up was lost, then begins at 124,100", describe(got))

        hand = Pen.Hand()
        _ = hand.handle(.chord(down: true))
        _ = hand.handle(.down(p1, flagged: true))
        _ = hand.handle(.chord(down: false))
        got = hand.handle(.down(p2, flagged: false))
        expect(got == Outcome(verdict: .pass, finished: Finished(points: 1, from: p1, to: p1, sealed: true)) && !hand.wantsTap,
               "after the chord, the next plain down finishes the sealed stroke and passes", describe(got))

        hand = Pen.Hand()
        got = hand.handle(.down(p1, flagged: false))
        expect(got == Outcome(verdict: .pass), "without the chord a down passes", describe(got))
        _ = hand.handle(.chord(down: true))
        got = hand.handle(.dragged(p2))
        expect(got == Outcome(verdict: .pass), "the chord arriving mid-press leaves that press's drags to the app", describe(got))
        got = hand.handle(.up(p2))
        expect(got == Outcome(verdict: .pass), "and its up", describe(got))
        got = hand.handle(.chord(down: false))
        expect(got == Outcome(verdict: .pass, mark: .chordUp), "the chord going up releases", describe(got))
        got = hand.handle(.chord(down: false))
        expect(got == Outcome(verdict: .pass) && !hand.wantsTap, "a second chord-up does nothing", describe(got))
    }

    static func post(_ virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: virtualKey, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func run() async {
        let state = AppState()
        let hotkey = Hotkey(state: state, pen: Pen(state: state))

        await hotkey.start()
        await hotkey.start()
        var taps = ownTaps()
        expect(taps.count == 1, "two start() calls leave one tap", "\(taps.count) taps")
        expect(taps.allSatisfy(\.enabled), "the tap is enabled", "\(taps.map(\.enabled))")
        expect(activeTaps().isEmpty, "no active tap before the chord", "\(activeTaps().count)")

        post(59, down: true, flags: .maskControl)
        try? await Task.sleep(for: .milliseconds(100))
        post(58, down: true, flags: [.maskControl, .maskAlternate])
        try? await Task.sleep(for: .milliseconds(600))
        let pen = activeTaps()
        expect(pen.count == 1 && pen.allSatisfy { $0.enabled && $0.eventsOfInterest == 70 },
               "during the chord one enabled active tap takes left down, up and drag (mask 70)",
               "\(pen.map { "enabled \($0.enabled) mask \($0.eventsOfInterest)" })")
        await hotkey.start()
        post(58, down: false, flags: .maskControl)
        try? await Task.sleep(for: .milliseconds(100))
        post(59, down: false, flags: [])
        try? await Task.sleep(for: .milliseconds(300))
        expect(state.held == [true, false], "start() mid-keypress keeps the hold [true, false]", "\(state.held)")
        taps = ownTaps()
        expect(taps.count == 1 && taps.allSatisfy(\.enabled), "still one enabled tap after the keypress", "\(taps.map(\.enabled))")
        expect(activeTaps().isEmpty, "300 ms after the chord the pen's tap is gone", "\(activeTaps().count)")
        expect(state.marks == [.chordUp], "a chord with no clicks tells AppState only .chordUp", "\(state.marks)")
    }
}
