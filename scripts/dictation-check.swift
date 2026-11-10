import Foundation

@main
enum DictationCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func same(_ got: [Dictation.Effect], _ expected: [Dictation.Effect], _ what: String) {
        expect(got == expected, got == expected ? what : "\(what)\n       got      \(got)\n       expected \(expected)")
    }

    static let t0 = ContinuousClock.now

    static func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    static func turn(_ order: Int, _ text: String, formatted: Bool = true, end: Bool = false, through audioEnd: Duration? = nil) -> AssemblyAI.Turn {
        AssemblyAI.Turn(order: order, text: text, isFormatted: formatted, endsTurn: end, audioEnd: audioEnd)
    }

    static func span(_ hold: Int, _ pressed: Int, _ released: Int?) -> Dictation.Span {
        Dictation.Span(hold: hold, pressed: at(pressed), released: released.map(at))
    }

    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let partial = turn(0, "Open the", through: .milliseconds(1500))
    static let answer = turn(0, "Open the settings page.", end: true, through: .milliseconds(2000))
    static let sentence = AssemblyAI.Final.heard("Open the settings page.")

    // Panel open at t0, Begin at +900, one hold from +2000 to +4000 with 20 real-time frames.
    static func warmHold(panel: Bool = true) -> Dictation {
        var dictation = Dictation()
        _ = dictation.handle(.panel(open: true), at: at(0))
        _ = dictation.handle(.began(session: 1), at: at(900))
        _ = dictation.press(at: at(2000))
        for frame in 1...20 {
            _ = dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(2000 + 100 * frame))
            if frame == 15 { _ = dictation.handle(.heard(session: 1, partial), at: at(3500)) }
        }
        if !panel { _ = dictation.handle(.panel(open: false), at: at(3900)) }
        _ = dictation.handle(.release, at: at(4000))
        _ = dictation.handle(.streamed(session: 1, hold: 1), at: at(4000))
        return dictation
    }

    // The same, with ForceEndpoint at +5000 and its answer delivered at +5300.
    static func delivered() -> Dictation {
        var dictation = warmHold()
        _ = dictation.handle(.tick, at: at(5000))
        _ = dictation.handle(.heard(session: 1, answer), at: at(5300))
        return dictation
    }

    static func main() {
        checkOneHold()
        checkMerge()
        checkNewUtterance()
        checkGate()
        checkBacklog()
        checkFallback()
        checkFailures()
        checkIdle()
        checkWarmBudget()
        checkTenInARow()
        checkSecondRelease()
        checkStaleAndClose()
        fuzz()
        exit(failures == 0 ? 0 : 1)
    }

    static func checkOneHold() {
        print("one hold")
        var dictation = Dictation()
        same(dictation.handle(.panel(open: true), at: at(0)), [.connect(session: 1, cause: .panel)], "opening the panel connects")
        same(dictation.handle(.panel(open: true), at: at(10)), [], "opening it again while connecting does not connect twice")
        same(dictation.handle(.began(session: 1), at: at(900)), [], "Begin with nothing held streams nothing")
        let (press, pressed) = dictation.press(at: at(2000))
        expect(press == Dictation.Press(hold: 1, utterance: 1), "the first press is hold 1 of utterance 1, got \(press)")
        same(pressed, [.stream(hold: 1, utterance: 1, session: 1)], "a press on an open socket streams at once")
        expect(dictation.words(of: 1) == "", "a new utterance shows no words")
        for frame in 1...15 { _ = dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(2000 + 100 * frame)) }
        same(dictation.handle(.heard(session: 1, partial), at: at(3500)), [.heard(session: 1, utterance: 1, partial)], "a partial belongs to the owner")
        expect(dictation.words(of: 1) == "Open the", "the words show while held, got \(String(describing: dictation.words(of: 1)))")
        for frame in 16...20 { _ = dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(2000 + 100 * frame)) }
        same(dictation.handle(.release, at: at(4000)), [], "the release waits for the tail frame")
        same(
            dictation.handle(.streamed(session: 1, hold: 1), at: at(4000)),
            [.finishing(session: 1, utterance: 1, plan: .endpoint, lag: .zero)],
            "once the tail is out and the server is caught up, ForceEndpoint waits only for the merge window"
        )
        expect(dictation.deadline == at(5000), "ForceEndpoint is due 1 s after the release")
        same(dictation.handle(.tick, at: at(4999)), [], "a tick 1 ms early sends nothing")
        same(dictation.handle(.tick, at: at(5000)), [.endpoint(session: 1)], "1 s after the release with no press, ForceEndpoint goes")
        same(dictation.handle(.tick, at: at(5000)), [], "a second tick sends nothing")
        same(
            dictation.handle(.heard(session: 1, answer), at: at(5300)),
            [
                .heard(session: 1, utterance: 1, answer),
                .final(session: 1, utterance: 1, sentence, via: .endpoint),
                .deliver(session: 1, utterance: 1, sentence, via: .endpoint, spans: [span(1, 2000, 4000)]),
            ],
            "the formatted end answers, and the utterance is delivered once"
        )
        expect(dictation.words(of: 1) == nil, "a delivered utterance is no longer live")
    }

    static func checkMerge() {
        print("merge")
        var dictation = warmHold()
        var between: [Dictation.Effect] = []
        let (press, pressed) = dictation.press(at: at(4800))
        expect(press == Dictation.Press(hold: 2, utterance: 1), "a press 0.8 s after the release joins utterance 1, got \(press)")
        same(pressed, [.stream(hold: 2, utterance: 1, session: 1)], "the joined hold streams on the same socket")
        expect(dictation.words(of: 1) == "Open the", "a joined hold starts from the words so far")
        expect(dictation.deadline == nil, "nothing is due while held")
        for frame in 1...15 { between += dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(4800 + 100 * frame)) }
        let more = turn(0, "Open the settings page, then click", through: .milliseconds(3400))
        between += dictation.handle(.heard(session: 1, more), at: at(6300))
        expect(dictation.words(of: 1) == "Open the settings page, then click", "the second hold continues the first hold's turn, got \(String(describing: dictation.words(of: 1)))")
        between += dictation.handle(.release, at: at(6300))
        same(
            dictation.handle(.streamed(session: 1, hold: 2), at: at(6300)),
            [.finishing(session: 1, utterance: 1, plan: .endpoint, lag: .milliseconds(100))],
            "the joined hold finishes"
        )
        expect(!between.contains(.endpoint(session: 1)), "no ForceEndpoint went between the holds, got \(between)")
        expect(dictation.deadline == at(7300), "the one ForceEndpoint is due 1 s after the second release")
        same(dictation.handle(.tick, at: at(7300)), [.endpoint(session: 1)], "and goes then")
        let end = turn(0, "Open the settings page, then click the button.", end: true, through: .milliseconds(3500))
        let whole = AssemblyAI.Final.heard("Open the settings page, then click the button.")
        same(
            dictation.handle(.heard(session: 1, end), at: at(7600)),
            [
                .heard(session: 1, utterance: 1, end),
                .final(session: 1, utterance: 1, whole, via: .endpoint),
                .deliver(session: 1, utterance: 1, whole, via: .endpoint, spans: [span(1, 2000, 4000), span(2, 4800, 6300)]),
            ],
            "one answer delivers one sentence carrying both holds"
        )
    }

    static func checkNewUtterance() {
        print("new utterance")
        var dictation = warmHold()
        let (press, pressed) = dictation.press(at: at(5200))
        expect(press == Dictation.Press(hold: 2, utterance: 2), "a press 1.2 s after the release starts utterance 2, got \(press)")
        same(pressed, [.endpoint(session: 1)], "the window that ran out sends utterance 1's ForceEndpoint first")
        expect(dictation.words(of: 2) == "", "utterance 2 starts empty")
        same(
            dictation.handle(.heard(session: 1, answer), at: at(5500)),
            [
                .heard(session: 1, utterance: 1, answer),
                .final(session: 1, utterance: 1, sentence, via: .endpoint),
                .deliver(session: 1, utterance: 1, sentence, via: .endpoint, spans: [span(1, 2000, 4000)]),
                .stream(hold: 2, utterance: 2, session: 1),
            ],
            "the answer delivers utterance 1 before the new hold streams"
        )
        let twin = turn(0, "open the settings page", formatted: false, end: true)
        same(dictation.handle(.heard(session: 1, twin), at: at(5600)), [.heard(session: 1, utterance: nil, twin)], "a turn from utterance 1 arriving now is late")
        expect(dictation.words(of: 2) == "", "utterance 2 never shows utterance 1's words")
        let own = turn(1, "Close it")
        same(dictation.handle(.heard(session: 1, own), at: at(5700)), [.heard(session: 1, utterance: 2, own)], "turn 1 belongs to utterance 2")
        expect(dictation.words(of: 2) == "Close it", "utterance 2 shows only its own words")
    }

    static func checkGate() {
        print("gate")
        var dictation = warmHold()
        let (press, pressed) = dictation.press(at: at(5200))
        expect(press == Dictation.Press(hold: 2, utterance: 2), "a press 1.2 s after a release still finishing starts utterance 2")
        same(pressed, [.endpoint(session: 1)], "utterance 2 waits while utterance 1's ForceEndpoint is out")
        var edge = warmHold()
        expect(edge.press(at: at(4999)).0 == Dictation.Press(hold: 2, utterance: 1), "a press 999 ms after the release joins")
        var past = warmHold()
        expect(past.press(at: at(5000)).0 == Dictation.Press(hold: 2, utterance: 2), "a press 1000 ms after the release starts a new utterance")
        same(
            dictation.handle(.heard(session: 1, answer), at: at(5300)),
            [
                .heard(session: 1, utterance: 1, answer),
                .final(session: 1, utterance: 1, sentence, via: .endpoint),
                .deliver(session: 1, utterance: 1, sentence, via: .endpoint, spans: [span(1, 2000, 4000)]),
                .stream(hold: 2, utterance: 2, session: 1),
            ],
            "the late answer settles and delivers utterance 1 at once, then utterance 2 streams"
        )

        var behind = Dictation()
        _ = behind.press(at: at(0))
        _ = behind.handle(.began(session: 1), at: at(2500))
        for _ in 1...25 { _ = behind.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(2500)) }
        _ = behind.handle(.release, at: at(2500))
        same(
            behind.handle(.streamed(session: 1, hold: 1), at: at(2500)),
            [.finishing(session: 1, utterance: 1, plan: .wait(.milliseconds(900)), lag: nil)],
            "a 2.5 s flush keeps ForceEndpoint 0.9 s past the merge window"
        )
        same(behind.press(at: at(3600)).1, [], "a new utterance pressed while the server is still behind waits, though no ForceEndpoint is out yet")
        same(behind.handle(.tick, at: at(4400)), [.endpoint(session: 1)], "ForceEndpoint goes once the server has caught up")
        let caughtUp = turn(0, "Open the settings page.", end: true, through: .milliseconds(2400))
        same(
            behind.handle(.heard(session: 1, caughtUp), at: at(4700)),
            [
                .heard(session: 1, utterance: 1, caughtUp),
                .final(session: 1, utterance: 1, sentence, via: .endpoint),
                .deliver(session: 1, utterance: 1, sentence, via: .endpoint, spans: [span(1, 0, 2500)]),
                .stream(hold: 2, utterance: 2, session: 1),
            ],
            "then utterance 1 delivers and utterance 2 streams"
        )
    }

    static func checkBacklog() {
        print("backlog")
        var dictation = Dictation()
        same(dictation.press(at: at(0)).1, [.connect(session: 1, cause: .press)], "a press with no socket connects")
        same(dictation.handle(.began(session: 1), at: at(800)), [.stream(hold: 1, utterance: 1, session: 1)], "Begin streams the queued hold")
        for _ in 1...25 { _ = dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(800)) }
        _ = dictation.handle(.release, at: at(800))
        same(
            dictation.handle(.streamed(session: 1, hold: 1), at: at(800)),
            [.finishing(session: 1, utterance: 1, plan: .wait(.milliseconds(900)), lag: nil)],
            "a 2.5 s flush that clears after the merge window waits 0.9 s past it for the server"
        )
        var worded = dictation
        expect(dictation.deadline == at(2700), "ForceEndpoint is due at +2700")
        same(dictation.handle(.tick, at: at(2699)), [], "not before")
        same(dictation.handle(.tick, at: at(2700)), [.endpoint(session: 1)], "the tick at +2700 sends ForceEndpoint")

        let caughtUp = turn(0, "Open", through: .milliseconds(2400))
        same(worded.handle(.heard(session: 1, caughtUp), at: at(850)), [.heard(session: 1, utterance: 1, caughtUp)], "a word showing a 100 ms lag sends nothing inside the window")
        expect(worded.deadline == at(1800), "but brings ForceEndpoint back to the window's end at +1800")

        var joined = Dictation()
        _ = joined.press(at: at(0))
        _ = joined.handle(.began(session: 1), at: at(800))
        for _ in 1...25 { _ = joined.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(800)) }
        _ = joined.handle(.release, at: at(800))
        _ = joined.handle(.streamed(session: 1, hold: 1), at: at(800))
        same(joined.press(at: at(900)).1, [.stream(hold: 2, utterance: 1, session: 1)], "a press inside the window joins and streams")
        expect(joined.deadline == nil, "and the wanted ForceEndpoint is dropped")
        same(joined.handle(.tick, at: at(2700)), [], "so nothing goes at +2700")
    }

    static func checkFallback() {
        print("fallback")
        var dictation = warmHold()
        same(dictation.handle(.tick, at: at(5000)), [.endpoint(session: 1)], "ForceEndpoint goes at the window's end")
        expect(dictation.deadline == at(7800), "no answer is overdue 2.8 s after ForceEndpoint")
        same(
            dictation.handle(.tick, at: at(7800)),
            [
                .final(session: 1, utterance: 1, .heard("Open the"), via: .fallback),
                .deliver(session: 1, utterance: 1, .heard("Open the"), via: .fallback, spans: [span(1, 2000, 4000)]),
                .close(session: 1, reason: .retire),
                .connect(session: 2, cause: .panel),
            ],
            "the owner delivers its words so far, the socket retires, and the open panel warms a new one"
        )
        same(dictation.handle(.heard(session: 1, answer), at: at(8000)), [.heard(session: 1, utterance: nil, answer)], "the late answer on the retired socket changes nothing")

        var closed = warmHold(panel: false)
        _ = closed.handle(.tick, at: at(5000))
        same(
            closed.handle(.tick, at: at(7800)),
            [
                .final(session: 1, utterance: 1, .heard("Open the"), via: .fallback),
                .deliver(session: 1, utterance: 1, .heard("Open the"), via: .fallback, spans: [span(1, 2000, 4000)]),
                .close(session: 1, reason: .retire),
            ],
            "with the panel closed, no new socket"
        )
    }

    static func checkFailures() {
        print("failures")
        let dropped = AssemblyAI.Failure.serverError(code: 1011, reason: "Internal error")
        var held = Dictation()
        _ = held.handle(.panel(open: true), at: at(0))
        _ = held.handle(.began(session: 1), at: at(900))
        _ = held.press(at: at(2000))
        same(
            held.handle(.failed(session: 1, dropped), at: at(2500)),
            [.final(session: 1, utterance: 1, .failed(dropped), via: .failure), .deliver(session: 1, utterance: 1, .failed(dropped), via: .failure, spans: [span(1, 2000, nil)])],
            "a failure while held delivers the failure, with no reconnect"
        )
        same(held.handle(.failed(session: 1, dropped), at: at(2600)), [], "a second report of the same failure changes nothing")
        same(held.handle(.release, at: at(3000)), [], "the release after it finds nothing to finish")
        same(held.press(at: at(3500)).1, [.connect(session: 2, cause: .press)], "the next press opens a fresh socket")

        var answering = warmHold()
        _ = answering.handle(.tick, at: at(5000))
        same(
            answering.handle(.failed(session: 1, dropped), at: at(5100)),
            [.final(session: 1, utterance: 1, .failed(dropped), via: .failure), .deliver(session: 1, utterance: 1, .failed(dropped), via: .failure, spans: [span(1, 2000, 4000)])],
            "a failure before the answer delivers the failure"
        )

        var queued = warmHold()
        _ = queued.press(at: at(5200))
        _ = queued.handle(.release, at: at(6000))
        same(
            queued.handle(.failed(session: 1, dropped), at: at(6100)),
            [
                .final(session: 1, utterance: 1, .failed(dropped), via: .failure),
                .deliver(session: 1, utterance: 1, .failed(dropped), via: .failure, spans: [span(1, 2000, 4000)]),
                .connect(session: 2, cause: .carry),
            ],
            "a hold that never reached the failed socket carries to a new one"
        )
        same(queued.handle(.began(session: 2), at: at(7000)), [.stream(hold: 2, utterance: 2, session: 2)], "and streams there")
        same(
            queued.handle(.streamed(session: 2, hold: 2), at: at(7000)),
            [.finishing(session: 2, utterance: 2, plan: .endpoint, lag: nil), .endpoint(session: 2)],
            "its window ran out before it streamed, so ForceEndpoint goes at once"
        )

        var connecting = Dictation()
        _ = connecting.press(at: at(0))
        _ = connecting.handle(.release, at: at(3000))
        same(
            connecting.handle(.failed(session: 1, .timedOut), at: at(5000)),
            [.final(session: 1, utterance: 1, .failed(.timedOut), via: .failure), .deliver(session: 1, utterance: 1, .failed(.timedOut), via: .failure, spans: [span(1, 0, 3000)])],
            "a connect failure fails the hold that waited on it"
        )
        expect(connecting.deadline == nil, "and nothing is left to do")
    }

    static func checkIdle() {
        print("idle")
        var closed = delivered()
        same(closed.handle(.panel(open: false), at: at(10_000)), [], "closing the panel closes nothing yet")
        expect(closed.deadline == at(40_000), "the session closes 30 s after the panel closed")
        var pressed = closed
        same(closed.handle(.tick, at: at(39_999)), [], "not before")
        same(closed.handle(.tick, at: at(40_000)), [.close(session: 1, reason: .idle)], "30 s with no hold and the panel closed closes the session")
        expect(closed.deadline == nil, "and nothing is due after")
        same(closed.press(at: at(41_000)).1, [.connect(session: 2, cause: .press)], "the next press reconnects")

        same(pressed.press(at: at(39_000)).1, [.stream(hold: 2, utterance: 2, session: 1)], "a press at +39 s streams on the open socket")
        same(pressed.handle(.tick, at: at(40_000)), [], "and the idle close does not happen")

        var open = delivered()
        expect(open.deadline == at(124_000), "with the panel open, the session closes 2 min after the release")
        same(open.handle(.tick, at: at(123_999)), [], "not before")
        same(open.handle(.tick, at: at(124_000)), [.close(session: 1, reason: .idle)], "2 min with no hold closes it")

        var reopened = delivered()
        _ = reopened.handle(.panel(open: false), at: at(10_000))
        same(reopened.handle(.panel(open: true), at: at(20_000)), [], "reopening the panel with the socket up connects nothing")
        expect(reopened.deadline == at(140_000), "and restarts the 2 min")

        var connecting = Dictation()
        _ = connecting.handle(.panel(open: true), at: at(0))
        _ = connecting.handle(.panel(open: false), at: at(100))
        same(connecting.handle(.tick, at: at(30_100)), [.close(session: 1, reason: .idle)], "a socket still connecting closes too")
        same(connecting.handle(.began(session: 1), at: at(30_200)), [.close(session: 1, reason: .stale)], "and its late Begin is closed as stale")
    }

    static func checkWarmBudget() {
        print("warm budget")
        let refused = AssemblyAI.Failure.serverError(code: 1008, reason: "Unauthorized Connection: Too many concurrent sessions")
        var dictation = Dictation()
        same(dictation.handle(.panel(open: true), at: at(0)), [.connect(session: 1, cause: .panel)], "open 1 warms")
        _ = dictation.handle(.failed(session: 1, refused), at: at(100))
        _ = dictation.handle(.panel(open: false), at: at(200))
        same(dictation.handle(.panel(open: true), at: at(300)), [.connect(session: 2, cause: .panel)], "open 2 warms")
        _ = dictation.handle(.failed(session: 2, refused), at: at(400))
        _ = dictation.handle(.panel(open: false), at: at(500))
        same(dictation.handle(.panel(open: true), at: at(600)), [.connect(session: 3, cause: .panel)], "open 3 warms")
        _ = dictation.handle(.failed(session: 3, refused), at: at(700))
        _ = dictation.handle(.panel(open: false), at: at(800))
        same(dictation.handle(.panel(open: true), at: at(900)), [], "a 4th open within the minute does not")
        same(dictation.press(at: at(1000)).1, [.connect(session: 4, cause: .press)], "a press always connects")
        _ = dictation.handle(.failed(session: 4, refused), at: at(1100))
        _ = dictation.handle(.release, at: at(1200))
        same(dictation.handle(.panel(open: true), at: at(60_299)), [], "at +60.299 s three connects are still within the minute")
        same(dictation.handle(.panel(open: true), at: at(60_300)), [.connect(session: 5, cause: .panel)], "at +60.300 s the one from +0.300 has aged out, so it warms")
    }

    static func checkTenInARow() {
        print("ten in a row")
        var dictation = Dictation()
        var effects = dictation.handle(.panel(open: true), at: at(0))
        effects += dictation.handle(.began(session: 1), at: at(900))
        for index in 0..<10 {
            let start = 2000 + index * 3000
            effects += dictation.press(at: at(start)).1
            for frame in 1...10 { effects += dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(start + 100 * frame)) }
            effects += dictation.handle(.release, at: at(start + 1000))
            effects += dictation.handle(.streamed(session: 1, hold: index + 1), at: at(start + 1000))
            effects += dictation.handle(.tick, at: at(start + 2000))
            effects += dictation.handle(.heard(session: 1, turn(index, "Sentence \(index + 1).", end: true)), at: at(start + 2300))
        }
        let connects = effects.filter { if case .connect = $0 { true } else { false } }
        expect(effects.filter { $0 == .endpoint(session: 1) }.count == 10, "one ForceEndpoint per utterance")
        let delivered = effects.compactMap { effect -> String? in
            guard case .deliver(let session, let utterance, .heard(let text), _, let spans) = effect else { return nil }
            return "\(session ?? 0)/\(utterance)/\(spans.count)/\(text)"
        }
        expect(connects == [.connect(session: 1, cause: .panel)], "ten utterances use the one warm connect, got \(connects)")
        expect(delivered == (1...10).map { "1/\($0)/1/Sentence \($0)." }, "utterances 1 to 10 are each delivered once with their own sentence, got \(delivered)")
    }

    static func checkSecondRelease() {
        print("second release")
        var dictation = warmHold()
        same(dictation.press(at: at(4100)).1, [.stream(hold: 2, utterance: 1, session: 1)], "a press 0.1 s after the release joins")
        _ = dictation.handle(.sent(session: 1, audio: .milliseconds(100)), at: at(4200))
        _ = dictation.handle(.release, at: at(4200))
        same(
            dictation.handle(.streamed(session: 1, hold: 2), at: at(4200)),
            [.finishing(session: 1, utterance: 1, plan: .endpoint, lag: .zero)],
            "the second hold finishes"
        )
        expect(dictation.deadline == at(5200), "the window restarts at the second release")
        same(dictation.handle(.tick, at: at(5000)), [], "so the first release's window sends nothing")
        same(dictation.handle(.tick, at: at(5200)), [.endpoint(session: 1)], "ForceEndpoint goes 1 s after the second release")

        var early = Dictation()
        _ = early.handle(.panel(open: true), at: at(0))
        _ = early.handle(.began(session: 1), at: at(900))
        _ = early.press(at: at(2000))
        same(early.handle(.streamed(session: 1, hold: 1), at: at(3000)), [], "a tail reported before the release finishes nothing")
        same(early.handle(.release, at: at(3100)), [.finishing(session: 1, utterance: 1, plan: .endpoint, lag: nil)], "the release then finishes")
        expect(early.deadline == at(4100), "with ForceEndpoint due 1 s later")
    }

    static func checkStaleAndClose() {
        print("close")
        var up = warmHold()
        same(up.handle(.began(session: 1), at: at(4400)), [], "a repeated Begin on the open socket changes nothing")
        let quit = AssemblyAI.Final.failed(.transport("Sherpa closed the session"))
        same(
            up.handle(.close, at: at(4500)),
            [
                .final(session: 1, utterance: 1, quit, via: .failure),
                .deliver(session: 1, utterance: 1, quit, via: .failure, spans: [span(1, 2000, 4000)]),
                .close(session: 1, reason: .quit),
            ],
            "quit inside the merge window fails the utterance and closes the socket"
        )
        same(up.handle(.close, at: at(4600)), [], "a second quit does nothing")

        var connecting = Dictation()
        _ = connecting.press(at: at(0))
        let closed = AssemblyAI.Final.failed(.transport("Sherpa closed the session"))
        same(
            connecting.handle(.close, at: at(100)),
            [.final(session: 1, utterance: 1, closed, via: .failure), .deliver(session: 1, utterance: 1, closed, via: .failure, spans: [span(1, 0, nil)]), .close(session: 1, reason: .quit)],
            "quit while connecting fails the waiting hold"
        )
        same(connecting.handle(.panel(open: true), at: at(200)), [.connect(session: 2, cause: .panel)], "the transcriber stays usable after a quit")
    }

    static func fuzz() {
        print("fuzz")
        var random = SplitMix64(state: 14)
        var dictation = Dictation()
        var now = t0
        var holding = false
        var pressed: Set<Int> = []
        var deliveries: [Int: Int] = [:]
        var foldedInto: [String: Set<Int>] = [:]
        var sessionsOf: [Int: Set<Int>] = [:]
        var connecting: [Int] = []
        var streaming: [Int: Int] = [:]
        var orders: [Int: Int] = [:]
        var newestSession = 0
        var problems: [String] = []
        var seen: [String: Int] = [:]
        var held = 0
        var released: [Int: ContinuousClock.Instant] = [:]
        var finishingOn: [Int: Int] = [:]

        func owned(_ text: String, by utterance: Int) -> Bool {
            text.split(separator: " ").allSatisfy { word in
                let parts = word.dropFirst().split(separator: "T").compactMap { Int($0) }
                return parts.count == 2 && foldedInto["\(parts[0]).\(parts[1])"] == [utterance]
            }
        }

        func absorb(_ effects: [Dictation.Effect], _ label: String) {
            for effect in effects {
                switch effect {
                case .final(_, _, _, let via): seen["final via \(via)", default: 0] += 1
                case .endpoint: seen["endpoint", default: 0] += 1
                default: break
                }
                switch effect {
                case .connect(let session, _):
                    connecting.append(session)
                    newestSession = max(newestSession, session)
                case .stream(let hold, let utterance, let session):
                    streaming[session] = hold
                    sessionsOf[utterance, default: []].insert(session)
                case .finishing(let session, let utterance, _, _):
                    finishingOn[session] = utterance
                case .endpoint(let session):
                    if let utterance = finishingOn[session], let release = released[utterance], now < release + .seconds(1) {
                        problems.append("\(label): ForceEndpoint for utterance \(utterance) went \(release.duration(to: now)) after its release")
                    }
                case .close(let session, _):
                    connecting.removeAll { $0 == session }
                    streaming[session] = nil
                case .heard(let session, let utterance?, let turn):
                    foldedInto["\(session).\(turn.order)", default: []].insert(utterance)
                case .deliver(_, let utterance, let final, _, _):
                    deliveries[utterance, default: 0] += 1
                    if case .heard(let text) = final, !owned(text, by: utterance) {
                        problems.append("\(label): utterance \(utterance) delivered '\(text)' with a turn it does not own")
                    }
                default:
                    break
                }
            }
        }

        for step in 0..<20_000 {
            now += .milliseconds(Int.random(in: 0...300, using: &random))
            let session = Int.random(in: 0..<4, using: &random) > 0 ? max(1, newestSession) : Int.random(in: max(1, newestSession - 1)...(newestSession + 1), using: &random)
            let roll = Int.random(in: 0..<100, using: &random)
            let label = "step \(step) roll \(roll)"
            var effects: [Dictation.Effect]
            switch roll {
            case 0..<14:
                if holding {
                    released[held] = now
                    effects = dictation.handle(.release, at: now)
                } else {
                    let (press, pressEffects) = dictation.press(at: now)
                    if pressed.contains(press.utterance) { seen["joined press", default: 0] += 1 }
                    pressed.insert(press.utterance)
                    held = press.utterance
                    effects = pressEffects
                }
                holding.toggle()
            case 14..<17:
                effects = dictation.handle(.panel(open: Bool.random(using: &random)), at: now)
            case 17..<26:
                let target = connecting.randomElement(using: &random) ?? session
                connecting.removeAll { $0 == target }
                effects = dictation.handle(.began(session: target), at: now)
            case 26..<42:
                effects = dictation.handle(.sent(session: session, audio: .milliseconds(Int.random(in: 50...1000, using: &random))), at: now)
            case 42..<52:
                let hold = streaming[session] ?? Int.random(in: 1...20, using: &random)
                streaming[session] = nil
                effects = dictation.handle(.streamed(session: session, hold: hold), at: now)
            case 52..<84:
                let order = max(0, orders[session, default: 0] + Int.random(in: -2...1, using: &random))
                let ends = Int.random(in: 0..<3, using: &random) == 0
                let empty = Int.random(in: 0..<5, using: &random) == 0
                let heard = turn(
                    order, empty ? "" : "S\(session)T\(order)", formatted: Bool.random(using: &random), end: ends,
                    through: empty ? nil : .milliseconds(Int.random(in: 0...20_000, using: &random))
                )
                if ends { orders[session] = max(orders[session, default: 0], order + 1) }
                effects = dictation.handle(.heard(session: session, heard), at: now)
            case 84:
                connecting.removeAll { $0 == session }
                streaming[session] = nil
                effects = dictation.handle(.failed(session: session, .serverError(code: 1011, reason: "")), at: now)
            case 85..<99:
                effects = dictation.handle(.tick, at: now)
            default:
                effects = dictation.handle(.close, at: now)
            }
            absorb(effects, label)
            absorb(dictation.handle(.tick, at: now), label)
            let again = dictation.handle(.tick, at: now)
            if !again.isEmpty { problems.append("\(label): a second tick at the same instant did \(again)") }
            let newest = pressed.max() ?? 0
            if let text = dictation.words(of: newest), !text.isEmpty, !owned(text, by: newest) {
                problems.append("\(label): utterance \(newest) showed '\(text)' with a turn it does not own")
            }
        }

        if holding {
            released[held] = now
            absorb(dictation.handle(.release, at: now), "drain release")
        }
        let drainStart = now
        var drained: Duration?
        for _ in 0..<240 {
            now += .milliseconds(500)
            for session in connecting.sorted() {
                connecting.removeAll { $0 == session }
                absorb(dictation.handle(.began(session: session), at: now), "drain")
            }
            for (session, hold) in streaming.sorted(by: { $0.key < $1.key }) {
                streaming[session] = nil
                absorb(dictation.handle(.streamed(session: session, hold: hold), at: now), "drain")
            }
            absorb(dictation.handle(.tick, at: now), "drain")
            if drained == nil, Set(deliveries.keys) == pressed { drained = drainStart.duration(to: now) }
        }

        let twice = deliveries.filter { $0.value > 1 }.keys.sorted()
        let missing = pressed.subtracting(deliveries.keys).sorted()
        let shared = foldedInto.filter { $0.value.count > 1 }.keys.sorted()
        let spanning = sessionsOf.filter { $0.value.count > 1 }.keys.sorted()
        print("  info \(pressed.count) utterances over \(newestSession) sessions, \(foldedInto.count) turns folded, drained in \(drained.map { "\($0)" } ?? "never")")
        print("  info \(seen.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        expect(twice.isEmpty, "20,000 seeded events: no utterance is delivered twice, got \(twice)")
        expect(missing.isEmpty && drained.map { $0 <= .seconds(60) } == true, "every utterance is delivered within 60 s once the shell answers, missing \(missing)")
        expect(shared.isEmpty, "no turn folds into two utterances, got \(shared.prefix(5))")
        expect(spanning.isEmpty, "no utterance streams on two sockets, got \(spanning.prefix(5))")
        expect(problems.isEmpty, "every tick is idempotent, no ForceEndpoint goes inside a merge window, and every delivery and panel shows only its own turns, got \(problems.count): \(problems.prefix(3))")
    }
}
