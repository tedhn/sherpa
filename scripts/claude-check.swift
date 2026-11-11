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
            one.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"L","type":"text"},{"source":{"data":"/9j/2Q==","media_type":"image/jpeg","type":"base64"},"type":"image"},{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"}}"#,
            "one image renders its label, the image, then the words, got \(one.map(body) ?? "nil")"
        )
        let none = try? Claude.request(Claude.Question(images: [], text: "T"), to: endpoint)
        expect(
            none.map(body) == #"{"max_tokens":16000,"messages":[{"content":[{"text":"T","type":"text"}],"role":"user"}],"model":"claude-haiku-5-5","output_config":{"effort":"low"}}"#,
            "no images leaves only the words, got \(none.map(body) ?? "nil")"
        )
        expect(one?.httpMethod == "POST", "the request is a POST")
        expect(one?.url?.absoluteString == "https://example.test/v1/messages", "the request goes to the endpoint, got \(one?.url?.absoluteString ?? "nil")")
        expect(one?.timeoutInterval == 120, "a non-streaming reply gets 120 s, got \(one?.timeoutInterval ?? 0)")
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

    static func answer(_ status: Int, _ text: String) -> Result<String, Claude.Failure> {
        do { return .success(try Claude.answer(status: status, body: Data(text.utf8))) } catch { return .failure(error) }
    }

    static func checkAnswer() {
        print("answer")
        let thinking = #"{"type":"thinking","thinking":""}"#
        expect(
            answer(200, #"{"content":[\#(thinking),{"type":"text","text":"  It is a desk.\n"}],"stop_reason":"end_turn"}"#) == .success("It is a desk."),
            "a thinking block is skipped and the text is trimmed"
        )
        expect(
            answer(200, #"{"content":[{"type":"text","text":"Hello, "},{"type":"text","text":"world."}],"stop_reason":"end_turn"}"#) == .success("Hello, world."),
            "two text blocks join without a separator"
        )
        expect(answer(200, #"{"content":[],"stop_reason":"refusal"}"#) == .failure(.declined), "a refusal is declined")
        expect(
            answer(200, #"{"content":[\#(thinking)],"stop_reason":"max_tokens"}"#) == .failure(.unanswered(status: 200, detail: "no text, stop_reason=max_tokens")),
            "thinking alone is unanswered and names the stop reason"
        )
        let unauthorized = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        expect(
            answer(401, unauthorized) == .failure(.keyRefused(status: 401, detail: "authentication_error: invalid x-api-key")),
            "a 401 is keyRefused with the error type and message"
        )
        expect(
            answer(403, unauthorized) == .failure(.keyRefused(status: 403, detail: "authentication_error: invalid x-api-key")),
            "a 403 is keyRefused"
        )
        expect(
            answer(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#) == .failure(.busy(status: 429, detail: "rate_limit_error: slow down")),
            "a 429 is busy"
        )
        expect(
            answer(529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) == .failure(.busy(status: 529, detail: "overloaded_error: Overloaded")),
            "a 529 is busy"
        )
        expect(
            answer(502, "<html>bad gateway</html>") == .failure(.busy(status: 502, detail: "<html>bad gateway</html>")),
            "a 502 with a page for a body is busy, with the page as detail"
        )
        expect(
            answer(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#) == .failure(.unanswered(status: 400, detail: "invalid_request_error: bad")),
            "a 400 is unanswered"
        )
        expect(answer(200, "not json") == .failure(.unanswered(status: 200, detail: "not json")), "a 200 that is not a message is unanswered")
        let long = String(repeating: "x", count: 300)
        expect(
            answer(502, long) == .failure(.busy(status: 502, detail: String(repeating: "x", count: 200))),
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
            text: "What colour is the image? Answer in one word.",
            screenshots: [shot(display: 1, cursor: .zero)]
        )
        do {
            let reply = try await Conversation(endpoint: Claude.Endpoint(url: Claude.Endpoint.production, key: key), urlSession: .shared)
                .answer(question, utterance: 1)
            print("  ok   answered: \(reply)")
        } catch {
            print("  FAIL \(error.logFields)")
            exit(1)
        }
    }
}
