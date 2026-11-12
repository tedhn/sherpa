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

    static func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    static func shot(display: CGDirectDisplayID, cursor: CGPoint) -> Screenshot {
        let context = CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return Screenshot(encoding: context.makeImage()!, display: display, appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100), cursor: cursor)!
    }

    static func main() async {
        if CommandLine.arguments.contains("--live") {
            await live()
            return
        }
        checkRequest()
        checkQuestion()
        checkAnswer()
        checkFailureFields()
        exit(failures == 0 ? 0 : 1)
    }

    static func checkRequest() {
        print("request")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let one = try? Claude.request(Claude.Question(images: [.init(label: "L", jpeg: jpeg)], text: "T"), to: endpoint)
        expect(
            one.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"L","type":"text"},{"source":{"data":"/9j/2Q==","media_type":"image/jpeg","type":"base64"},"type":"image"},{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"},"stream":true}"#,
            "one image renders its label, the image, then the words, got \(one.map(body) ?? "nil")"
        )
        let none = try? Claude.request(Claude.Question(images: [], text: "T"), to: endpoint)
        expect(
            none.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"},"stream":true}"#,
            "no images leaves only the words, got \(none.map(body) ?? "nil")"
        )
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
                _ = try Claude.request(Claude.Question(images: [], text: "T"), to: Claude.Endpoint(url: endpoint.url, key: key))
                expect(false, "key \(String(describing: key)) throws")
            } catch {
                expect(error == .noAPIKey, "key \(String(describing: key)) throws noAPIKey, got \(error)")
            }
        }
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

    static func failure(_ status: Int, _ text: String) -> Claude.Failure {
        Claude.failure(status: status, body: Data(text.utf8))
    }

    static func stream(_ lines: [String]) -> Result<String, Claude.Failure> {
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

    static func checkAnswer() {
        print("answer")
        expect(
            stream(start + [delta("  A menu bar app"), delta(" is a small"), delta(" tool.\\n")] + end) == .success("A menu bar app is a small tool."),
            "text deltas concatenate and the result is trimmed"
        )
        var reading = Claude.Answer()
        var seen: [String] = []
        for line in start + ["event: content_block_delta", delta("A menu"), "", delta(" bar app."), "", "data: not json", "data: [DONE]"] + end {
            try? reading.read(line)
            if seen.last != reading.shown { seen.append(reading.shown) }
        }
        expect(seen == ["", "A menu", "A menu bar app."], "shown grows with each delta and nothing else changes it, got \(seen)")
        let thinking = [
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ]
        expect(stream(thinking + start + [delta("Hi.")] + end) == .success("Hi."), "a thinking block adds no text")
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
        let started = ContinuousClock.now
        let ms = { (instant: ContinuousClock.Instant) in Int((instant.duration(to: .now) / .milliseconds(1)).rounded()) }
        var updates = 0
        var first: Int?
        do {
            let reply = try await Conversation(endpoint: Claude.Endpoint(url: Claude.Endpoint.production, key: key), urlSession: .shared)
                .answer(question, utterance: 1) { _ in
                    updates += 1
                    if first == nil { first = ms(started) }
                }
            print("  first text \(first ?? 0) ms, total \(ms(started)) ms, \(updates) updates")
            print("  \(reply)")
            expect(updates >= 2, "the answer arrived in at least 2 updates, got \(updates)")
        } catch {
            print("  FAIL \(error.logFields)")
            exit(1)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
