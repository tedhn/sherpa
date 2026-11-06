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
            url.absoluteString == "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&encoding=pcm_s16le&format_turns=true&speech_model=universal-streaming-english&token=abc.123-x",
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
        expect(worded == .turn(AssemblyAI.Turn(order: 0, text: "Open the", isFormatted: true, endsTurn: false, audioEnd: 1520)), "a Turn's audio end is its last word's end, got \(worded)")
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

    static func turn(_ order: Int, _ text: String, formatted: Bool = true, end: Bool = false, through audioEnd: Int? = nil) -> AssemblyAI.Turn {
        AssemblyAI.Turn(order: order, text: text, isFormatted: formatted, endsTurn: end, audioEnd: audioEnd)
    }

    static func checkTranscript() {
        expect(AssemblyAI.Control.forceEndpoint.rawValue == #"{"type":"ForceEndpoint"}"#, "ForceEndpoint is its bare type message")
        expect(AssemblyAI.Transcript().shown == .hearing(""), "a new hold shows no words")

        var two = AssemblyAI.Transcript()
        let held = [
            two.hear(turn(0, "Open the"), sentThrough: 0),
            two.hear(turn(0, "Open the Settings page."), sentThrough: 0),
            two.hear(turn(0, "open the settings page", formatted: false, end: true), sentThrough: 0),
            two.hear(turn(0, "Open the Settings page.", end: true), sentThrough: 0),
            two.hear(turn(0, "open the settings page", formatted: false, end: true), sentThrough: 0),
            two.hear(turn(1, "Then click"), sentThrough: 0),
        ]
        expect(held.allSatisfy { $0 == nil }, "no end_of_turn delivers before ForceEndpoint")
        expect(two.shown == .hearing("Open the Settings page. Then click"), "turns join in order, a formatted end outranks a later unformatted one, and the partial shows, got \(two.shown)")
        two.forceEndpoint()
        let sentence = "Open the Settings page. Then click the blue button at the top."
        let answer = two.hear(turn(1, "Then click the blue button at the top.", end: true), sentThrough: 0)
        expect(answer == .heard(sentence), "turn 1's formatted end answers ForceEndpoint with both turns, got \(String(describing: answer))")
        let drained = [two.hear(turn(2, "", end: true), sentThrough: 0), two.settle(), two.fail(.timedOut)]
        expect(drained.allSatisfy { $0 == nil }, "after the answer, Terminate's empty end turn, the fallback and a drain failure deliver nothing")
        expect(two.shown == .final(.heard(sentence)), "the panel keeps the final through the drain, got \(two.shown)")

        var quiet = AssemblyAI.Transcript()
        quiet.forceEndpoint()
        expect(quiet.hear(turn(0, "", end: true), sentThrough: 0) == .silence, "an empty answer with no words is silence")

        var paused = AssemblyAI.Transcript()
        _ = paused.hear(turn(0, "Open the Settings page.", end: true), sentThrough: 0)
        paused.forceEndpoint()
        expect(paused.hear(turn(1, "", end: true), sentThrough: 0) == .heard("Open the Settings page."), "an empty answer after an ended turn delivers that turn")

        var twin = AssemblyAI.Transcript()
        _ = twin.hear(turn(0, "open settings", formatted: false, end: true), sentThrough: 0)
        twin.forceEndpoint()
        let late = twin.hear(turn(0, "Open settings.", end: true), sentThrough: 0)
        expect(late == nil && twin.shown == .hearing("Open settings."), "a late formatted twin below the floor updates the words but does not answer")
        expect(twin.hear(turn(1, "", end: true), sentThrough: 0) == .heard("Open settings."), "the order-1 answer delivers the formatted text")

        var rough = AssemblyAI.Transcript()
        _ = rough.hear(turn(0, "open"), sentThrough: 0)
        rough.forceEndpoint()
        let unformatted = rough.hear(turn(0, "open settings", formatted: false, end: true), sentThrough: 0)
        rough.forceEndpoint()
        let formatted = rough.hear(turn(0, "Open settings.", end: true), sentThrough: 0)
        expect(unformatted == nil && formatted == .heard("Open settings."), "an unformatted end waits for its formatted twin, and the first floor stands")

        var slow = AssemblyAI.Transcript()
        _ = slow.hear(turn(0, "Open the Set"), sentThrough: 0)
        slow.forceEndpoint()
        expect(slow.settle() == .heard("Open the Set"), "the fallback delivers the words so far")
        expect(slow.hear(turn(0, "Open the Settings page.", end: true), sentThrough: 0) == nil && slow.shown == .final(.heard("Open the Set")), "an answer after the fallback changes nothing")

        var nothing = AssemblyAI.Transcript()
        nothing.forceEndpoint()
        expect(nothing.settle() == .silence, "a fallback with no words is silence")

        var broken = AssemblyAI.Transcript()
        _ = broken.hear(turn(0, "Open"), sentThrough: 0)
        expect(broken.fail(.transport("lost")) == .failed(.transport("lost")) && broken.settle() == nil, "a failure first is the one delivery")

        var blank = AssemblyAI.Transcript()
        _ = blank.hear(turn(0, "  "), sentThrough: 0)
        blank.forceEndpoint()
        expect(blank.hear(turn(0, " ", end: true), sentThrough: 0) == .silence, "whitespace is no words")

        var shuffled = AssemblyAI.Transcript()
        _ = shuffled.hear(turn(1, "Second."), sentThrough: 0)
        _ = shuffled.hear(turn(0, "First.", end: true), sentThrough: 0)
        expect(shuffled.text == "First. Second.", "text follows turn order, not arrival order, got \(shuffled.text)")

        var terminated = AssemblyAI.Transcript()
        let unanswered = [
            terminated.hear(turn(0, "Open the Settings page.", end: true, through: 1360), sentThrough: 0),
            terminated.hear(turn(1, "Then click the blue button.", end: true, through: 3480), sentThrough: 0),
            terminated.hear(turn(2, "", end: true), sentThrough: 0),
        ]
        expect(unanswered.allSatisfy { $0 == nil }, "without ForceEndpoint no end_of_turn delivers, so Terminate's turns all fold")
        expect(terminated.settle() == .heard("Open the Settings page. Then click the blue button."), "settling on Termination delivers every turn")

        var lag = AssemblyAI.Transcript()
        expect(lag.finish() == .terminate, "with no turns it terminates")
        _ = lag.hear(turn(0, "Open the", through: 2340), sentThrough: 2640)
        expect(lag.lastLag == 300 && lag.finish() == .endpoint, "a word ending at 2340 heard at 2640 ms is a lag of 300, which ends by ForceEndpoint, got \(String(describing: lag.lastLag))")
        _ = lag.hear(turn(0, "Open the", through: 1000), sentThrough: 1600)
        expect(lag.lastLag == 600 && lag.finish() == .endpoint, "a lag of 600 is still caught up")
        _ = lag.hear(turn(0, "Open the", through: 1000), sentThrough: 1601)
        expect(lag.lastLag == 601 && lag.finish() == .terminate, "a lag of 601 terminates")
        _ = lag.hear(turn(1, "", end: true), sentThrough: 5000)
        expect(lag.lastLag == 601, "a turn without a word end leaves the lag as it was, got \(String(describing: lag.lastLag))")
    }
}
