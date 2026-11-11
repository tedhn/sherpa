import Foundation

@main
enum AssemblyAICheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    static func pcm(_ count: Int, from start: Int = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: start + $0 % 251) | 1 })
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

    static func main() {
        let url = AssemblyAI.Endpoints.production.socketURL(token: "abc.123-x", sampleRate: 16_000)
        expect(
            url.absoluteString == "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le&format_turns=true&speech_model=universal-streaming-english&end_of_turn_confidence_threshold=1&min_end_of_turn_silence_when_confident=10000&max_turn_silence=10000&token=abc.123-x",
            "the socket URL carries every query parameter in order, got \(url.absoluteString)"
        )

        let request = AssemblyAI.tokenRequest(key: "sk-test", at: AssemblyAI.Endpoints.production.token)
        expect(request.url?.absoluteString == "https://token.assemblyai.com/v1/token", "the token request goes to the token endpoint")
        expect(request.httpMethod == "POST", "the token request is a POST, got \(request.httpMethod ?? "nil")")
        expect(request.value(forHTTPHeaderField: "Authorization") == "sk-test", "the key is the raw Authorization header, no Bearer")
        expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "the token request says its body is JSON")
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        expect(body == #"{"product":"streaming","expires_in_seconds":480}"#, "the token request asks for an 8-minute streaming token, got \(body ?? "nil")")
        expect(request.timeoutInterval == 5, "the token request gives up after 5 s")

        let minted = ContinuousClock.now
        let reply = try? AssemblyAI.token(status: 200, body: json(#"{"token":"tmp-1","expires_in_seconds":480}"#), mintedAt: minted)
        expect(reply == AssemblyAI.Token(value: "tmp-1", expires: minted + .seconds(480)), "a 200 reply yields its token expiring 480 s after it was minted, got \(String(describing: reply))")
        let now = ContinuousClock.now
        expect(AssemblyAI.Token(value: "t", expires: now + .seconds(31)).isUsable(at: now), "a token with 31 s left is usable")
        expect(!AssemblyAI.Token(value: "t", expires: now + .seconds(29)).isUsable(at: now), "a token with 29 s left is not usable")
        do {
            _ = try AssemblyAI.token(status: 401, body: json(#"{"error":"Invalid API key"}"#), mintedAt: minted)
            expect(false, "a 401 reply throws")
        } catch {
            expect(error == .tokenRefused(status: 401, detail: #"{"error":"Invalid API key"}"#), "a 401 reply is tokenRefused with the body as detail, got \(error)")
        }
        do {
            _ = try AssemblyAI.token(status: 500, body: Data(repeating: UInt8(ascii: "x"), count: 300), mintedAt: minted)
            expect(false, "a 500 reply throws")
        } catch {
            expect(error == .tokenRefused(status: 500, detail: String(repeating: "x", count: 200)), "a refusal's detail stops at 200 bytes")
        }

        let begin = AssemblyAI.ServerEvent(json: json(#"{"type":"Begin","id":"s1","expires_at":1762000000}"#))
        expect(begin == .began, "Begin parses as began, got \(begin)")
        let turn = AssemblyAI.ServerEvent(json: json(#"{"type":"Turn","turn_order":2,"turn_is_formatted":true,"end_of_turn":true,"end_of_turn_confidence":0.9,"transcript":"Hello world.","utterance":"","words":[]}"#))
        expect(turn == .turn(AssemblyAI.Turn(order: 2, text: "Hello world.", isFormatted: true, endsTurn: true, audioEnd: nil)), "Turn parses its order, text and flags, and no words is no audio end, got \(turn)")
        let worded = AssemblyAI.ServerEvent(json: json(#"{"type":"Turn","turn_order":0,"turn_is_formatted":true,"end_of_turn":false,"transcript":"Open the","words":[{"text":"Open","start":1200,"end":1360,"confidence":0.9,"word_is_final":true},{"text":"the","start":1400,"end":1520,"confidence":0.8,"word_is_final":false}]}"#))
        expect(worded == .turn(AssemblyAI.Turn(order: 0, text: "Open the", isFormatted: true, endsTurn: false, audioEnd: .milliseconds(1520))), "a Turn's audio end is its last word's end, got \(worded)")
        let wordless = AssemblyAI.ServerEvent(json: json(#"{"type":"Turn","turn_order":1,"turn_is_formatted":true,"end_of_turn":true,"transcript":""}"#))
        expect(wordless == .turn(AssemblyAI.Turn(order: 1, text: "", isFormatted: true, endsTurn: true, audioEnd: nil)), "a Turn without words is not malformed, got \(wordless)")
        let termination = AssemblyAI.ServerEvent(json: json(#"{"type":"Termination","audio_duration_seconds":2.5,"session_duration_seconds":3.1}"#))
        expect(termination == .terminated(audioSeconds: 2.5), "Termination parses its audio duration, got \(termination)")
        let started = AssemblyAI.ServerEvent(json: json(#"{"type":"SpeechStarted","timestamp":120,"confidence":0.8}"#))
        expect(started == .ignored(type: "SpeechStarted"), "SpeechStarted is ignored by name, got \(started)")
        let refusal = AssemblyAI.ServerEvent(json: json(#"{"type":"Error","error_code":1008,"error":"Unauthorized Connection: Too many concurrent sessions"}"#))
        expect(refusal == .error(code: 1008, reason: "Unauthorized Connection: Too many concurrent sessions"), "Error parses its code and reason, got \(refusal)")
        let codeless = AssemblyAI.ServerEvent(json: json(#"{"type":"Error","error":"Unauthorized Connection: Too many concurrent sessions"}"#))
        expect(codeless == .error(code: 0, reason: "Unauthorized Connection: Too many concurrent sessions"), "an Error without error_code reads as code 0 with its reason, got \(codeless)")
        let nope = AssemblyAI.ServerEvent(json: json("nope"))
        expect(nope == .malformed(type: nil), "a frame that is not JSON is malformed, got \(nope)")
        let untold = AssemblyAI.ServerEvent(json: json(#"{"type":"Turn","turn_order":0,"turn_is_formatted":false,"end_of_turn":false}"#))
        expect(untold == .malformed(type: "Turn"), "a Turn without a transcript is a malformed Turn, got \(untold)")

        var live = AssemblyAI.Framer(sampleRate: 16_000)
        let first = pcm(2752), second = pcm(3200, from: 7)
        let firstOut = live.take(first)
        let secondOut = live.take(second)
        expect(firstOut == [first] && secondOut == [second], "2752 then 3200 bytes leave as two frames as they arrive, got \(firstOut.map(\.count)) then \(secondOut.map(\.count))")
        expect(live.finish() == nil, "nothing is left to finish after whole frames")

        var short = AssemblyAI.Framer(sampleRate: 16_000)
        let thousand = pcm(1000)
        let shortOut = short.take(thousand)
        let padded = short.finish()
        expect(shortOut.isEmpty, "1000 bytes, under 50 ms, leave nothing, got \(shortOut.map(\.count))")
        expect(padded == thousand + Data(count: 600), "finish gives those 1000 bytes padded with zeros to 1600, got \(padded?.count ?? 0) bytes")

        var backlog = AssemblyAI.Framer(sampleRate: 16_000)
        let forty = pcm(40_000)
        let fortyOut = backlog.take(forty)
        expect(fortyOut.map(\.count) == [32_000, 8_000] && fortyOut.reduce(Data(), +) == forty, "40000 pending bytes leave as 32000 then 8000, got \(fortyOut.map(\.count))")
        var over = AssemblyAI.Framer(sampleRate: 16_000)
        let overOut = over.take(pcm(32_600))
        expect(overOut.map(\.count) == [32_000], "32600 pending bytes leave as 32000 and 600 wait, got \(overOut.map(\.count))")
        expect(over.finish()?.count == 1600, "the waiting 600 bytes finish as one padded 1600-byte frame")

        var random = SplitMix64(state: 12)
        var fuzz = AssemblyAI.Framer(sampleRate: 16_000)
        var input = Data()
        var frames: [Data] = []
        for index in 0..<400 {
            let size = index % 10 == 0 ? Int.random(in: 0...40_000, using: &random) : Int.random(in: 0...4_000, using: &random)
            let chunk = Data((0..<size).map { _ in UInt8.random(in: 1...255, using: &random) })
            input.append(chunk)
            frames += fuzz.take(chunk)
        }
        let tail = fuzz.finish()
        let sizes = frames.map(\.count) + [tail?.count ?? 0]
        let sent = frames.reduce(Data(), +) + (tail ?? Data())
        expect(sizes.allSatisfy { $0 % 2 == 0 && (1600...32_000).contains($0) }, "400 seeded random chunks leave as even frames of 1600 to 32000 bytes, sizes \(sizes.min() ?? 0) to \(sizes.max() ?? 0)")
        expect(tail?.count == 1600, "the final frame is padded to exactly 1600 bytes, got \(tail?.count ?? 0)")
        expect(
            sent.prefix(input.count) == input && sent.dropFirst(input.count).allSatisfy { $0 == 0 } && sent.count - input.count <= 1600,
            "the frames are the \(input.count) input bytes in order plus \(sent.count - input.count) zero bytes of padding"
        )

        let unauthorized = AssemblyAI.Failure(URLError(.networkConnectionLost), closeCode: 1008, closeReason: json("Unauthorized Connection: Invalid API key"))
        expect(unauthorized == .serverError(code: 1008, reason: "Unauthorized Connection: Invalid API key"), "a 1008 close outranks the error that surfaced, got \(unauthorized)")
        let offline = AssemblyAI.Failure(
            URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."]),
            closeCode: 0, closeReason: nil
        )
        expect(offline == .transport("Could not connect to the server."), "a URLError with no close code is transport with its description, got \(offline)")
        let late = AssemblyAI.Failure(AssemblyAI.Failure.timedOut, closeCode: 1001, closeReason: nil)
        expect(late == .timedOut, "timedOut stays timedOut over the 1001 its own cancel set, got \(late)")

        let expired = AssemblyAI.Failure.serverError(code: 1008, reason: "Unauthorized Connection: Signature has expired")
        expect(expired.isExpiredToken, "the 1008 signature-expired refusal is an expired token")
        expect(!unauthorized.isExpiredToken, "the 1008 invalid-key refusal is not an expired token")
        expect(!AssemblyAI.Failure.timedOut.isExpiredToken, "timedOut is not an expired token")

        expect(unauthorized.logFields == "reason=serverError code=1008 detail=Unauthorized Connection: Invalid API key", "a server error renders its code then the reason, got \(unauthorized.logFields)")
        expect(AssemblyAI.Failure.noAPIKey.logFields == "reason=noAPIKey", "noAPIKey renders as one field")
        let refused = AssemblyAI.Failure.tokenRefused(status: 401, detail: #"{"error":"Invalid API key"}"#).logFields
        expect(refused == #"reason=tokenRefused status=401 detail={"error":"Invalid API key"}"#, "a refusal renders its status then the body, got \(refused)")
        expect(AssemblyAI.Failure.timedOut.logFields == "reason=timedOut", "timedOut renders as one field")
        expect(offline.logFields == "reason=transport detail=Could not connect to the server.", "transport renders its detail last, got \(offline.logFields)")

        checkTranscript()
        exit(failures == 0 ? 0 : 1)
    }

    static func turn(_ order: Int, _ text: String, formatted: Bool = true, end: Bool = false, through audioEnd: Duration? = nil) -> AssemblyAI.Turn {
        AssemblyAI.Turn(order: order, text: text, isFormatted: formatted, endsTurn: end, audioEnd: audioEnd)
    }

    static func checkTranscript() {
        expect(AssemblyAI.Control.forceEndpoint.rawValue == #"{"type":"ForceEndpoint"}"#, "ForceEndpoint is its bare type message")
        expect(AssemblyAI.Transcript().text == "" && AssemblyAI.Transcript().final == .silence, "a new transcript has no words and is silence")

        var two = AssemblyAI.Transcript()
        for heard in [
            turn(0, "Open the"),
            turn(0, "Open the Settings page."),
            turn(0, "open the settings page", formatted: false, end: true),
            turn(0, "Open the Settings page.", end: true),
            turn(0, "open the settings page", formatted: false, end: true),
            turn(1, "Then click"),
        ] { two.hear(heard) }
        expect(two.text == "Open the Settings page. Then click", "turns join in order, a formatted end outranks a later unformatted one, and the partial shows, got \(two.text)")
        two.hear(turn(1, "Then click the blue button at the top.", end: true))
        expect(two.final == .heard("Open the Settings page. Then click the blue button at the top."), "the final is both turns, got \(two.final)")

        var shuffled = AssemblyAI.Transcript()
        shuffled.hear(turn(1, "Second."))
        shuffled.hear(turn(0, "First.", end: true))
        expect(shuffled.text == "First. Second.", "text follows turn order, not arrival order, got \(shuffled.text)")

        var blank = AssemblyAI.Transcript()
        blank.hear(turn(0, "  "))
        blank.hear(turn(0, " ", end: true))
        expect(blank.final == .silence, "whitespace is no words, got \(blank.final)")

        checkLedger()
    }

    static func checkLedger() {
        let t0 = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

        var caught = AssemblyAI.Ledger(began: t0)
        for frame in 0..<26 { caught.sent(.milliseconds(100), at: at(100 * frame)) }
        caught.sent(.milliseconds(40), at: at(2600))
        _ = caught.hear(turn(0, "Open the", through: .milliseconds(2340)), at: at(2640))
        caught.want(notBefore: t0)
        expect(caught.lastLag == .milliseconds(300) && caught.fire(at: at(2640)), "a word ending at 2340 heard at 2640 ms is a lag of 300, and ForceEndpoint goes at once")

        var edge = AssemblyAI.Ledger(began: t0)
        edge.sent(.milliseconds(1600), at: t0)
        _ = edge.hear(turn(0, "Open", through: .milliseconds(1000)), at: t0)
        edge.want(notBefore: t0)
        expect(edge.lastLag == .milliseconds(600) && edge.fire(at: t0), "a lag of 600 is caught up, so ForceEndpoint goes at once")
        var over = AssemblyAI.Ledger(began: t0)
        over.sent(.milliseconds(1601), at: t0)
        _ = over.hear(turn(0, "Open", through: .milliseconds(1000)), at: t0)
        over.want(notBefore: t0)
        expect(over.endpointDue == t0 + .milliseconds(1) && !over.fire(at: t0) && over.fire(at: at(1)), "a lag of 601 waits 1 ms")

        var flush = AssemblyAI.Ledger(began: t0)
        for _ in 0..<25 { flush.sent(.milliseconds(100), at: t0) }
        flush.want(notBefore: t0)
        expect(flush.endpointDue == at(1900), "a 2500 ms flush with no word yet is due at t0+1900, got \(String(describing: flush.endpointDue.map { t0.duration(to: $0) }))")
        let tightened = flush.hear(turn(0, "Open the", through: .milliseconds(2100)), at: at(1000))
        expect(!tightened && flush.endpointDue == at(1000) && flush.fire(at: at(1000)), "a word ending at 2100 heard at t0+1000 shows a 400 ms lag, so ForceEndpoint goes then")

        var steady = AssemblyAI.Ledger(began: t0)
        for frame in 1...26 { steady.sent(.milliseconds(100), at: at(100 * frame)) }
        steady.want(notBefore: t0)
        expect(steady.fire(at: at(2600)), "26 real-time frames of 100 ms and no turns: ForceEndpoint goes at the last frame")

        var window = AssemblyAI.Ledger(began: t0)
        for frame in 1...10 { window.sent(.milliseconds(100), at: at(100 * frame)) }
        window.want(notBefore: at(2000))
        expect(window.endpointDue == at(2000) && !window.fire(at: at(1999)) && window.fire(at: at(2000)), "caught up at t0+1000 but wanted not before t0+2000, ForceEndpoint goes at t0+2000")

        var cleared = AssemblyAI.Ledger(began: t0)
        for _ in 0..<25 { cleared.sent(.milliseconds(100), at: t0) }
        cleared.want(notBefore: at(1000))
        expect(cleared.endpointDue == at(1900), "wanted not before t0+1000 behind a 2500 ms flush, it is due once caught up at t0+1900, got \(String(describing: cleared.endpointDue.map { t0.duration(to: $0) }))")
        cleared.unwant()
        expect(cleared.endpointDue == nil && !cleared.fire(at: at(5000)), "an unwanted ForceEndpoint never goes")

        var two = AssemblyAI.Ledger(began: t0)
        let held = [
            two.hear(turn(0, "Open the"), at: t0),
            two.hear(turn(0, "open the settings page", formatted: false, end: true), at: t0),
            two.hear(turn(0, "Open the Settings page.", end: true), at: t0),
            two.hear(turn(1, "Then click"), at: t0),
        ]
        expect(held == [false, false, false, false], "no end_of_turn answers before ForceEndpoint")
        two.want(notBefore: t0)
        expect(two.fire(at: at(10)) && two.outstanding == AssemblyAI.Ledger.Outstanding(floor: 1, sentAt: at(10)), "ForceEndpoint with turn 1 open waits for turn 1 or later, got \(String(describing: two.outstanding))")
        expect(two.answerDue == at(2810), "no answer by 2.8 s after ForceEndpoint is overdue")
        two.want(notBefore: t0)
        expect(two.endpointDue == nil && !two.fire(at: at(20)), "a second ForceEndpoint waits while one is outstanding")
        expect(!two.hear(turn(0, "Open the Settings page.", end: true), at: at(100)), "a late end below the floor does not answer")
        expect(two.hear(turn(1, "Then click the blue button.", end: true), at: at(300)), "turn 1's formatted end answers")
        expect(two.nextOrder == 2 && two.outstanding == nil && two.answerDue == nil, "the answer ends turn 1, so the next utterance starts at turn 2")
        expect(two.endpointDue == t0 && two.fire(at: at(300)) && two.outstanding?.floor == 2, "the wanted ForceEndpoint goes once the answer is in, waiting for turn 2")
        expect(two.hear(turn(2, "", end: true), at: at(500)) && two.nextOrder == 3, "an empty end turn answers it")

        var quiet = AssemblyAI.Ledger(began: t0)
        quiet.want(notBefore: t0)
        _ = quiet.fire(at: t0)
        expect(quiet.hear(turn(0, "", end: true), at: t0), "with no turns, an empty end turn 0 answers")

        var paused = AssemblyAI.Ledger(began: t0)
        _ = paused.hear(turn(0, "Open the Settings page.", end: true), at: t0)
        paused.want(notBefore: t0)
        _ = paused.fire(at: t0)
        expect(paused.outstanding?.floor == 1 && paused.hear(turn(1, "", end: true), at: t0), "after an ended turn, an empty end turn 1 answers")

        var twin = AssemblyAI.Ledger(began: t0)
        _ = twin.hear(turn(0, "open settings", formatted: false, end: true), at: t0)
        twin.want(notBefore: t0)
        _ = twin.fire(at: t0)
        expect(!twin.hear(turn(0, "Open settings.", end: true), at: t0), "a formatted twin below the floor does not answer")
        expect(twin.hear(turn(1, "", end: true), at: t0), "the order-1 empty end answers")

        var rough = AssemblyAI.Ledger(began: t0)
        _ = rough.hear(turn(0, "open"), at: t0)
        rough.want(notBefore: t0)
        _ = rough.fire(at: t0)
        let unformatted = rough.hear(turn(0, "open settings", formatted: false, end: true), at: t0)
        rough.want(notBefore: t0)
        let refired = rough.fire(at: t0)
        let formatted = rough.hear(turn(0, "Open settings.", end: true), at: t0)
        expect(!unformatted && !refired && formatted && rough.outstanding == nil, "an unformatted end waits for its formatted twin, and the first floor stands")

        var orders = AssemblyAI.Ledger(began: t0)
        expect(orders.nextOrder == 0, "a new socket's first turn is 0")
        _ = orders.hear(turn(3, "Third.", end: true), at: t0)
        orders.want(notBefore: t0)
        _ = orders.fire(at: t0)
        _ = orders.hear(turn(4, "", end: true), at: t0)
        expect(orders.nextOrder == 5, "an answer at turn 4 makes the next order 5, got \(orders.nextOrder)")
        _ = orders.hear(turn(5, "stray"), at: t0)
        _ = orders.hear(turn(2, "older", end: true), at: t0)
        expect(orders.nextOrder == 6, "any turn already heard, even one no answer closed, is below the next order, got \(orders.nextOrder)")

        var lag = AssemblyAI.Ledger(began: t0)
        lag.sent(.milliseconds(5000), at: t0)
        _ = lag.hear(turn(0, "Open", through: .milliseconds(4399)), at: t0)
        _ = lag.hear(turn(1, "", end: true), at: at(10))
        expect(lag.lastLag == .milliseconds(601), "a turn without a word end leaves the lag as it was, got \(String(describing: lag.lastLag))")
    }
}
