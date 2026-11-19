import CoreGraphics
import Foundation

@main
enum ClaudeCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let endpoint = Claude.Endpoint(url: URL(string: "https://example.test/v1/messages")!, key: "k-123")

    static func fields(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
    }

    static func body(_ request: URLRequest) -> String {
        var rest = fields(request)
        rest["system"] = nil
        let data = (try? JSONSerialization.data(withJSONObject: rest, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func shot(display: CGDirectDisplayID, cursor: CGPoint, red: Double = 0.2, green: Double = 0.4, blue: Double = 0.6) -> Screenshot {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return Screenshot(encoding: context.makeImage()!, display: display, appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), cursor: cursor)!
    }

    static func main() async {
        if CommandLine.arguments.contains("--live") {
            await live()
            return
        }
        checkRequest()
        checkHistory()
        checkQuestion()
        checkCallout()
        checkSaid()
        checkAnswer()
        checkFailureFields()
        exit(failures == 0 ? 0 : 1)
    }

    static func checkRequest() {
        print("request")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let one = try? Claude.request(Claude.Question(images: [.init(label: "L", jpeg: jpeg)], text: "T"), after: [], to: endpoint)
        expect(
            one.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"L","type":"text"},{"source":{"data":"/9j/2Q==","media_type":"image/jpeg","type":"base64"},"type":"image"},{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"},"stream":true}"#,
            "one image renders its label, the image, then the words, got \(one.map(body) ?? "nil")"
        )
        let none = try? Claude.request(Claude.Question(images: [], text: "T"), after: [], to: endpoint)
        expect(
            none.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"},"stream":true}"#,
            "no images leaves only the words, got \(none.map(body) ?? "nil")"
        )
        let remembered = try? Claude.request(
            Claude.Question(images: [], text: "T"),
            after: [
                Claude.Exchange(question: "Q1", screens: 2, answer: "A1"),
                Claude.Exchange(question: "Q2", screens: 0, answer: "A2"),
                Claude.Exchange(question: "Q3", screens: 1, answer: "A3"),
            ],
            to: endpoint
        )
        let twoNote = "[You were shown 2 screenshots with this question and answered from them. They have been removed from the history to save space.]"
        let oneNote = "[You were shown 1 screenshot with this question and answered from it. It has been removed from the history to save space.]"
        expect(
            remembered.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"\#(twoNote)","type":"text"},{"text":"Q1","type":"text"}],"role":"user"},{"content":[{"text":"A1","type":"text"}],"role":"assistant"},{"content":[{"text":"Q2","type":"text"}],"role":"user"},{"content":[{"text":"A2","type":"text"}],"role":"assistant"},{"content":[{"text":"\#(oneNote)","type":"text"},{"text":"Q3","type":"text"}],"role":"user"},{"content":[{"text":"A3","type":"text"}],"role":"assistant"},{"content":[{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"},"stream":true}"#,
            "history renders as note and question, then answer, oldest first, before the current turn, got \(remembered.map(body) ?? "nil")"
        )
        expect(one.map { !((fields($0)["system"] as? String) ?? "").isEmpty } == true, "the request carries a non-empty system prompt")
        expect(one?.httpMethod == "POST", "the request is a POST")
        expect(one?.url?.absoluteString == "https://example.test/v1/messages", "the request goes to the endpoint, got \(one?.url?.absoluteString ?? "nil")")
        expect(
            one?.allHTTPHeaderFields == [
                "x-api-key": "k-123", "anthropic-version": "2026-10-21",
                "Content-Type": "application/json",
            ],
            "the three headers, got \(one?.allHTTPHeaderFields ?? [:])"
        )
        for key: String? in [nil, ""] {
            do {
                _ = try Claude.request(Claude.Question(images: [], text: "T"), after: [], to: Claude.Endpoint(url: endpoint.url, key: key))
                expect(false, "key \(String(describing: key)) throws")
            } catch {
                expect(error == .noAPIKey, "key \(String(describing: key)) throws noAPIKey, got \(error)")
            }
        }
    }

    static func checkHistory() {
        print("history")
        let start = ContinuousClock.now
        func exchange(_ number: Int) -> Claude.Exchange { Claude.Exchange(question: "q\(number)", screens: 1, answer: "a\(number)") }
        var history = Claude.History()
        for number in 1...12 { history.remember(exchange(number), at: start + .seconds(number)) }
        let kept = history.recalled(at: start + .seconds(13)).map(\.question)
        expect(kept == (3...12).map { "q\($0)" }, "the last ten of twelve are recalled in order, got \(kept)")
        expect(history.recalled(at: start + .seconds(12 + 29 * 60 + 59)).count == 10, "ten exchanges are recalled 29 min 59 s after the last")
        expect(history.recalled(at: start + .seconds(12 + 30 * 60)).isEmpty, "nothing is recalled 30 min after the last")
        history.remember(exchange(13), at: start + .seconds(31 * 60 + 12))
        expect(history.recalled(at: start + .seconds(31 * 60 + 12)) == [exchange(13)], "an exchange remembered after the idle gap leaves only itself")
        var short = Claude.History(forgetAfter: .seconds(2))
        short.remember(exchange(1), at: start)
        expect(short.recalled(at: start + .milliseconds(1999)).count == 1, "a 2 s history still recalls at 1.999 s")
        expect(short.recalled(at: start + .seconds(2)).isEmpty, "a 2 s history forgets at 2 s")
        expect(Claude.History().recalled(at: start).isEmpty, "an empty history recalls nothing")
    }

    static func checkQuestion() {
        print("question")
        let here = shot(display: 1, cursor: CGPoint(x: 10, y: 10))
        let there = shot(display: 2, cursor: CGPoint(x: 500, y: 500))
        let question = Claude.Question(text: "what is this", screenshots: [here, there])
        expect(
            question.images.map(\.label) == [
                "Screen 1 of 2. The cursor is on this screen. This image is 2x2 pixels.",
                "Screen 2 of 2. The cursor is not on this screen. This image is 2x2 pixels.",
            ],
            "screens are numbered in the order given, got \(question.images.map(\.label))"
        )
        expect(question.images.map(\.jpeg) == [here.jpeg, there.jpeg], "each image carries its own JPEG")
        expect(question.text == "what is this", "the words are kept, got \(question.text)")
        expect(Claude.Question(text: "hi", screenshots: []).images.isEmpty, "no screenshots means no images")
    }

    static func checkCallout() {
        print("callout")
        func sized(_ frame: CGRect) -> Screenshot {
            let context = CGContext(
                data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return Screenshot(encoding: context.makeImage()!, display: 1, appKitFrame: frame, cursor: .zero)!
        }
        let shots = [sized(CGRect(x: 0, y: 0, width: 8, height: 4)), sized(CGRect(x: 100, y: -40, width: 40, height: 20))]
        let want: [(Claude.Target, Callout?)] = [
            (.point(.init(x: 1, y: 0), label: "a", screen: 1), Callout(point: CGPoint(x: 3, y: 3), label: "a", bounds: nil)),
            (.point(.init(x: 1, y: 0), label: "a", screen: 2), Callout(point: CGPoint(x: 115, y: -25), label: "a", bounds: nil)),
            (.point(.init(x1: 1, y1: 0, x2: 2, y2: 1), label: "b", screen: 1),
             Callout(point: CGPoint(x: 3, y: 3), label: "b", bounds: CGRect(x: 2, y: 0, width: 4, height: 4))),
            (.point(.init(x1: 0, y1: 1, x2: 3, y2: 9), label: "c", screen: 2),
             Callout(point: CGPoint(x: 115, y: -35), label: "c", bounds: CGRect(x: 100, y: -40, width: 40, height: 10))),
            (.point(.init(x: 1, y: 0), label: "a", screen: 3), nil),
            (.point(.init(x: 1, y: 0), label: "a", screen: 0), nil),
            (.none, nil),
        ]
        for (target, expected) in want {
            let got = target.callout(on: shots)
            expect(got == expected, "\(target) calls out \(String(describing: expected)), got \(String(describing: got))")
        }
    }

    static func failure(_ status: Int, _ text: String) -> Claude.Failure {
        Claude.failure(status: status, body: Data(text.utf8))
    }

    static func stream(_ lines: [String]) -> Result<Claude.Said, Claude.Failure> {
        var reading = Claude.Answer()
        do {
            for line in lines { try reading.read(line) }
            return .success(try reading.finished())
        } catch { return .failure(error) }
    }

    static func delta(_ text: String) -> String {
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}            }"#
    }

    static let start = [
        "event: message_start",
        #"data: {"type":"message_start","message":{"model":"claude-haiku-5-5","id":"msg_1","type":"message","role":"assistant","content":[],"stop_reason":null}}"#,
        "",
        "event: content_block_start",
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}    }"#,
        "",
        "event: ping",
        #"data: {"type": "ping"}"#,
        "",
    ]
    static let end = [
        "event: content_block_stop",
        #"data: {"type":"content_block_stop","index":0       }"#,
        "",
        "event: message_delta",
        #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null,"stop_details":null},"usage":{"output_tokens":5}}"#,
        "",
        "event: message_stop",
        #"data: {"type":"message_stop"}"#,
        "",
    ]

    static func checkSaid() {
        print("said")
        let point = Claude.Target.point(.init(x: 12, y: 40), label: "Save", screen: 1)
        let panel = Claude.Target.point(.init(x1: 600, y1: 380, x2: 680, y2: 420), label: "panel", screen: 1)
        let probes: [(text: String, spoken: String, tag: String?, target: Claude.Target?)] = [
            ("Done. [POINT:none]", "Done.", "[POINT:none]", Claude.Target.none),
            ("Click it. [POINT:600,380,680,420:panel:screen1]", "Click it.", "[POINT:600,380,680,420:panel:screen1]", panel),
            ("Click it. [POINT:1212,72,1260,120:profile picture:screen2]", "Click it.", "[POINT:1212,72,1260,120:profile picture:screen2]",
             .point(.init(x1: 1212, y1: 72, x2: 1260, y2: 120), label: "profile picture", screen: 2)),
            ("Click it. [POINT:600,380,680,420:panel]", "Click it.", "[POINT:600,380,680,420:panel]", panel),
            ("Click it. [POINT:600 , 380, 680 ,420 :  panel  :screen1]\n", "Click it.", "[POINT:600 , 380, 680 ,420 :  panel  :screen1]", panel),
            ("Click it. [POINT:680,420,600,380:panel:screen1]", "Click it.", "[POINT:680,420,600,380:panel:screen1]", panel),
            ("Click it. [POINT:640,400,640,400:panel:screen1]", "Click it.", "[POINT:640,400,640,400:panel:screen1]", .point(.init(x: 640, y: 400), label: "panel", screen: 1)),
            ("Click it. [POINT:600,380,680:panel]", "Click it.", "[POINT:600,380,680:panel]", nil),
            ("Click it. [POINT:600,380,680,420,9:panel]", "Click it.", "[POINT:600,380,680,420,9:panel]", nil),
            ("Click it. [POINT:600,380,-680,420:panel]", "Click it.", "[POINT:600,380,-680,420:panel]", nil),
            ("Click it. [POINT:600,380,680,420:]", "Click it.", "[POINT:600,380,680,420:]", nil),
            ("Click it. [POINT:600,380,680,420]", "Click it.", "[POINT:600,380,680,420]", nil),
            ("Click it. [POINT:600,38", "Click it.", "[POINT:600,38", nil),
            ("Click it. [POINT:600,380,680,42", "Click it.", "[POINT:600,380,680,42", nil),
            ("Click it. [POINT:600,380,680,420:pan", "Click it.", "[POINT:600,380,680,420:pan", nil),
            ("Click it. [POINT:1012,199:Wi-Fi switch:screen2]", "Click it.", "[POINT:1012,199:Wi-Fi switch:screen2]", .point(.init(x: 1012, y: 199), label: "Wi-Fi switch", screen: 2)),
            ("Click it. [POINT:12,40:Save]", "Click it.", "[POINT:12,40:Save]", point),
            ("  Click it.  \n [POINT:12 , 40 :  Save  :screen2]\n\n", "Click it.", "[POINT:12 , 40 :  Save  :screen2]", .point(.init(x: 12, y: 40), label: "Save", screen: 2)),
            ("Click it. [POINT:12,40:Save]  ", "Click it.", "[POINT:12,40:Save]", point),
            ("Click [POINT:1,2:a] it. [POINT:none]", "Click [POINT:1,2:a] it.", "[POINT:none]", Claude.Target.none),
            ("Click [POINT:1,2:a] it.", "Click [POINT:1,2:a] it.", nil, nil),
            ("Click it. [point:none]", "Click it.", "[point:none]", nil),
            ("Click it. [POINT:12,40]", "Click it.", "[POINT:12,40]", nil),
            ("Click it. [POINT:12,40:]", "Click it.", "[POINT:12,40:]", nil),
            ("Click it. [POINT:12,40:Save:screen0]", "Click it.", "[POINT:12,40:Save:screen0]", nil),
            ("Click it. [POINT:12,40:Save:screen]", "Click it.", "[POINT:12,40:Save:screen]", nil),
            ("Click it. [POINT:-12,40:Save]", "Click it.", "[POINT:-12,40:Save]", nil),
            ("Click it. [POINT:none:screen1]", "Click it.", "[POINT:none:screen1]", nil),
            ("Click it. [", "Click it.", "[", nil),
            ("Click it. [POI", "Click it.", "[POI", nil),
            ("Click it. [POINT:12,4", "Click it.", "[POINT:12,4", nil),
            ("See [note]", "See [note]", nil, nil),
            ("Pick [1, 2]", "Pick [1, 2]", nil, nil),
            ("[POINT:none]", "", "[POINT:none]", Claude.Target.none),
            ("", "", nil, nil),
        ]
        for probe in probes {
            let said = Claude.Said(probe.text)
            expect(
                said.spoken == probe.spoken && said.tag == probe.tag && said.target == probe.target,
                "\(probe.text.debugDescription) splits into \(probe.spoken.debugDescription), \(probe.tag.debugDescription), \(String(describing: probe.target)), got \(said.spoken.debugDescription), \(said.tag.debugDescription), \(String(describing: said.target))"
            )
        }
        for example in Claude.system.matches(of: #/\[POINT:(?:none|[0-9][^\]]*)\]/#).map({ String($0.output) }) {
            expect(Claude.Said(example).target != nil, "the prompt example \(example) parses")
        }
        let pointing = Claude.system.matches(of: #/\[POINT:[0-9][^\]]*\]/#).map { Claude.Said(String($0.output)).target }
        expect(
            pointing == [
                .point(.init(x1: 196, y1: 2, x2: 226, y2: 22), label: "File menu", screen: 1),
                .point(.init(x1: 1212, y1: 72, x2: 1260, y2: 120), label: "profile picture", screen: 2),
            ],
            "the prompt's two pointing examples are boxes, got \(pointing)"
        )
    }

    static func checkAnswer() {
        print("answer")
        expect(
            stream(start + [delta("  A menu bar app"), delta(" is a small"), delta(" tool.\\n")] + end).map(\.spoken) == .success("A menu bar app is a small tool."),
            "text deltas concatenate and the result is trimmed"
        )
        var reading = Claude.Answer()
        var seen: [String] = []
        for line in start + ["event: content_block_delta", delta("A menu"), "", delta(" bar app."), "", "data: not json", "data: [DONE]"] + end {
            try? reading.read(line)
            if seen.last != reading.shown { seen.append(reading.shown) }
        }
        expect(seen == ["", "A menu", "A menu bar app."], "shown grows with each delta and nothing else changes it, got \(seen)")
        var tagged = Claude.Answer()
        var shown: [String] = []
        for line in start + ["Click File", " in the menu bar. [", "POINT:211,", "12:File menu:sc", "reen1]"].map(delta) {
            try? tagged.read(line)
            if shown.last != tagged.shown { shown.append(tagged.shown) }
        }
        expect(shown == ["", "Click File", "Click File in the menu bar."], "a tag as it streams in never shows, got \(shown)")
        let tail = stream(start + [delta("Click File"), delta(" in the menu bar. ["), delta("POINT:211,"), delta("12:File menu:sc"), delta("reen1]")] + end)
        expect(
            tail.map(\.spoken) == .success("Click File in the menu bar.") && tail.map(\.target) == .success(Claude.Target.point(.init(x: 211, y: 12), label: "File menu", screen: 1)),
            "a tag split across deltas is stripped and parsed, got \(tail)"
        )
        let boxed = ["Click File", " in the menu bar. [", "POINT:196,", "2,22", "6,22:File menu:sc", "reen1]"].map(delta)
        var boxShown: [String] = []
        var boxReading = Claude.Answer()
        for line in start + boxed {
            try? boxReading.read(line)
            if boxShown.last != boxReading.shown { boxShown.append(boxReading.shown) }
        }
        expect(boxShown == ["", "Click File", "Click File in the menu bar."], "a box tag as it streams in never shows, got \(boxShown)")
        let boxTail = stream(start + boxed + end)
        expect(
            boxTail.map(\.spoken) == .success("Click File in the menu bar.")
                && boxTail.map(\.target) == .success(Claude.Target.point(.init(x1: 196, y1: 2, x2: 226, y2: 22), label: "File menu", screen: 1)),
            "a box tag split across deltas is stripped and parsed, got \(boxTail)"
        )
        expect(
            stream(start + [delta("[POINT:none]")] + end) == .failure(.unanswered(status: 200, detail: "no text, stop_reason=end_turn")),
            "an answer that is only a tag is unanswered"
        )
        let thinking = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ]
        expect(stream(thinking + start + [delta("Hi.")] + end).map(\.spoken) == .success("Hi."), "a thinking block adds no text")
        expect(
            stream(start + [delta("Part of an answer"), #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"}}"#, #"data: {"type":"message_stop"}"#]) == .failure(.declined),
            "a refusal after some text is declined"
        )
        expect(
            stream(start + [delta("Part"), "event: error", #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#]) == .failure(.busy(status: 200, detail: "overloaded_error: Overloaded")),
            "an overloaded error event is busy"
        )
        expect(
            stream(start + [#"data: {"type":"error","error":{"type":"api_error","message":"oops"}}"#]) == .failure(.busy(status: 200, detail: "api_error: oops")),
            "an api error event is busy"
        )
        expect(
            stream(start + [#"data: {"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#]) == .failure(.unanswered(status: 200, detail: "invalid_request_error: bad")),
            "an invalid request error event is unanswered"
        )
        expect(
            stream(start + [delta("Cut off")]) == .failure(.unanswered(status: 200, detail: "the stream ended without a stop_reason")),
            "a stream with no message_delta is unanswered"
        )
        expect(
            stream(thinking + [#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#]) == .failure(.unanswered(status: 200, detail: "no text, stop_reason=max_tokens")),
            "thinking alone is unanswered and names the stop reason"
        )
        let unauthorized = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        expect(
            failure(401, unauthorized) == .keyRefused(status: 401, detail: "authentication_error: invalid x-api-key"),
            "a 401 is keyRefused with the error type and message"
        )
        expect(
            failure(403, unauthorized) == .keyRefused(status: 403, detail: "authentication_error: invalid x-api-key"),
            "a 403 is keyRefused"
        )
        expect(
            failure(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#) == .busy(status: 429, detail: "rate_limit_error: slow down"),
            "a 429 is busy"
        )
        expect(
            failure(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .busy(status: 529, detail: "overloaded_error: Overloaded"),
            "a 529 is busy"
        )
        expect(
            failure(502, "<html>bad gateway</html>") == .busy(status: 502, detail: "<html>bad gateway</html>"),
            "a 502 with a page for a body is busy, with the page as detail"
        )
        expect(
            failure(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#) == .unanswered(status: 400, detail: "invalid_request_error: bad"),
            "a 400 is unanswered"
        )
        let long = String(repeating: "x", count: 300)
        expect(
            failure(502, long) == .busy(status: 502, detail: String(repeating: "x", count: 200)),
            "a long body is cut to 200 bytes"
        )
    }

    static func checkFailureFields() {
        print("log fields")
        expect(Claude.Failure.noAPIKey.logFields == "reason=noAPIKey", "noAPIKey fields")
        expect(Claude.Failure.keyRefused(status: 401, detail: "no").logFields == "reason=keyRefused status=401 detail=no", "keyRefused fields")
        expect(Claude.Failure.busy(status: 529, detail: "full").logFields == "reason=busy status=529 detail=full", "busy fields")
        expect(Claude.Failure.declined.logFields == "reason=declined", "declined fields")
        expect(Claude.Failure.unanswered(status: 200, detail: "no text, stop_reason=none").logFields == "reason=unanswered status=200 detail=no text, stop_reason=none", "unanswered fields")
        expect(Claude.Failure.transport("offline").logFields == "reason=transport detail=offline", "transport fields")
    }

    static func live() async {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            print("skip no ANTHROPIC_API_KEY")
            exit(0)
        }
        let question = Claude.Question(
            text: "Describe the image in three short sentences.",
            screenshots: [shot(display: 1, cursor: .zero)]
        )
        let followUp = Claude.Question(
            text: "What colour was the image I showed you before?",
            screenshots: [shot(display: 1, cursor: .zero, red: 1, green: 0, blue: 0)]
        )
        let started = ContinuousClock.now
        let ms = { (instant: ContinuousClock.Instant) in Int((instant.duration(to: .now) / .milliseconds(1)).rounded()) }
        var updates = 0
        var first: Int?
        do {
            let conversation = Conversation(endpoint: Claude.Endpoint(url: Claude.Endpoint.production, key: key), urlSession: .shared)
            let reply = try await conversation.answer(question, utterance: 1) { _ in
                updates += 1
                if first == nil { first = ms(started) }
            }
            print("  first text \(first ?? 0) ms, total \(ms(started)) ms, \(updates) updates")
            print("  \(reply.spoken) \(reply.tag ?? "")")
            expect(updates >= 2, "the answer arrived in at least 2 updates, got \(updates)")
            let remembered = try await conversation.answer(followUp, utterance: 2) { _ in }
            print("  \(remembered.spoken)")
            expect(remembered.spoken.lowercased().contains("blue"), "the follow-up recalls the first image's colour")
        } catch {
            print("  FAIL \(error.logFields)")
            exit(1)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
