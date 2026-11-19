import Foundation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "claude")

nonisolated enum Claude {
    struct Endpoint: Equatable, Sendable {
        static let production = URL(string: "https://api.anthropic.com/v1/messages")!

        let url: URL
        let key: String?
    }

    struct Question: Equatable, Sendable {
        struct Image: Equatable, Sendable {
            let label: String
            let jpeg: Data
        }

        let images: [Image]
        let text: String
    }

    struct Exchange: Equatable, Sendable {
        let question: String
        let screens: Int
        let answer: String
    }

    struct History: Equatable, Sendable {
        static let kept = 10
        static let idle: Duration = .seconds(30 * 60)

        let forgetAfter: Duration
        private(set) var exchanges: [Exchange] = []
        private var last: ContinuousClock.Instant?

        init(forgetAfter: Duration = idle) {
            self.forgetAfter = forgetAfter
        }

        func recalled(at now: ContinuousClock.Instant) -> [Exchange] {
            guard let last, last.duration(to: now) < forgetAfter else { return [] }
            return exchanges
        }

        mutating func remember(_ exchange: Exchange, at now: ContinuousClock.Instant) {
            exchanges = Array((recalled(at: now) + [exchange]).suffix(Self.kept))
            last = now
        }
    }

    enum Target: Equatable, Sendable {
        case none
        case point(x: Int, y: Int, label: String, screen: Int)

        static let cursorScreen = 1

        var logField: String {
            switch self {
            case .none: "none"
            case .point(let x, let y, _, let screen): "screen\(screen):\(x),\(y)"
            }
        }
    }

    struct Said: Equatable, Sendable {
        let spoken: String
        let tag: String?
        let target: Target?

        init(_ text: String) {
            let suffix = #/(?i)\[(?:POINT:[^\]\n\r]*\]?|P(?:O(?:I(?:N(?:T)?)?)?)?)?\s*\z/#
            guard let match = text.firstMatch(of: suffix) else {
                (spoken, tag, target) = (text.trimmingCharacters(in: .whitespacesAndNewlines), nil, nil)
                return
            }
            let removed = match.output.trimmingCharacters(in: .whitespacesAndNewlines)
            spoken = text[..<match.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            tag = removed
            target = Self.parse(removed)
        }

        private static func parse(_ tag: String) -> Target? {
            let strict = #/\[POINT:(?:(none)|([0-9]+)\s*,\s*([0-9]+)\s*:([^\]:\n\r]+?)(?::screen([0-9]+))?)\]/#
            guard let match = tag.wholeMatch(of: strict) else { return nil }
            let (_, none, x, y, label, screen) = match.output
            if none != nil { return Target.none }
            let name = label?.trimmingCharacters(in: .whitespaces) ?? ""
            let number = screen.map { Int($0) ?? 0 } ?? Target.cursorScreen
            guard let x = x.flatMap({ Int($0) }), let y = y.flatMap({ Int($0) }), !name.isEmpty, number > 0 else { return nil }
            return .point(x: x, y: y, label: name, screen: number)
        }
    }

    enum Reply: Equatable, Sendable {
        case asking
        case answering(String)
        case answered(String)
        case failed(Failure)
    }

    enum Failure: Error, Equatable, Sendable {
        case noAPIKey
        case keyRefused(status: Int, detail: String)
        case busy(status: Int, detail: String)
        case declined
        case unanswered(status: Int, detail: String)
        case transport(String)

        var logFields: String {
            switch self {
            case .noAPIKey: "reason=noAPIKey"
            case .keyRefused(let status, let detail): "reason=keyRefused status=\(status) detail=\(detail)"
            case .busy(let status, let detail): "reason=busy status=\(status) detail=\(detail)"
            case .declined: "reason=declined"
            case .unanswered(let status, let detail): "reason=unanswered status=\(status) detail=\(detail)"
            case .transport(let detail): "reason=transport detail=\(detail)"
            }
        }
    }

    static func request(_ question: Question, after history: [Exchange], to endpoint: Endpoint) throws(Failure) -> URLRequest {
        guard let key = endpoint.key, !key.isEmpty else { throw .noAPIKey }
        var messages: [[String: Any]] = []
        for exchange in history {
            var turn: [[String: Any]] = []
            switch exchange.screens {
            case 0: break
            case 1: turn.append(["type": "text", "text": "[You were shown 1 screenshot with this question and answered from it. It has been removed from the history to save space.]"])
            default: turn.append(["type": "text", "text": "[You were shown \(exchange.screens) screenshots with this question and answered from them. They have been removed from the history to save space.]"])
            }
            turn.append(["type": "text", "text": exchange.question])
            messages.append(["role": "user", "content": turn])
            messages.append(["role": "assistant", "content": [["type": "text", "text": exchange.answer]]])
        }
        var content: [[String: Any]] = []
        for image in question.images {
            content.append(["type": "text", "text": image.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": question.text])
        messages.append(["role": "user", "content": content])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            "messages": messages,
            "stream": true,
            "system": system,
        ]
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    static func failure(status: Int, body: Data) -> Failure {
        let detail = (try? JSONDecoder().decode(WireError.self, from: body)).map { "\($0.error.type): \($0.error.message)" }
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        switch status {
        case 401, 403: return .keyRefused(status: status, detail: detail)
        case 429, 500...599: return .busy(status: status, detail: detail)
        default: return .unanswered(status: status, detail: detail)
        }
    }

    struct Answer {
        private var text = ""
        private var stopReason: String?

        var shown: String { Said(text).spoken }

        mutating func read(_ line: String) throws(Failure) {
            guard line.hasPrefix("data:"),
                  let event = try? JSONDecoder().decode(WireEvent.self, from: Data(line.dropFirst(5).utf8))
            else { return }
            switch event.type {
            case "content_block_delta":
                if event.delta?.type == "text_delta", let piece = event.delta?.text { text += piece }
            case "message_delta":
                stopReason = event.delta?.stop_reason
            case "error":
                guard let error = event.error else { return }
                let detail = "\(error.type): \(error.message)"
                switch error.type {
                case "overloaded_error", "api_error", "rate_limit_error": throw .busy(status: 200, detail: detail)
                default: throw .unanswered(status: 200, detail: detail)
                }
            default:
                break
            }
        }

        func finished() throws(Failure) -> Said {
            if stopReason == "refusal" { throw .declined }
            guard let stopReason else { throw .unanswered(status: 200, detail: "the stream ended without a stop_reason") }
            let said = Said(text)
            guard !said.spoken.isEmpty else { throw .unanswered(status: 200, detail: "no text, stop_reason=\(stopReason)") }
            return said
        }
    }

    private static let model = "claude-haiku-5-5"
    private static let version = "2026-10-21"
    private static let effort = "low"
    private static let maxTokens = 16000
    static let system = """
        You are Sherpa, a voice assistant in the user's Mac menu bar. The user speaks a question, and you get their words and a screenshot of each display. Your reply is spoken aloud by text-to-speech, so talk the way a sharp, friendly person sitting next to them would.

        Rules:
        - Answer in one to three short spoken sentences. Lead with the answer. Go longer only if asked.
        - Plain text only. Never use markdown, bullet points, numbered lists, headings, tables, code blocks, emoji, or URLs.
        - For steps, say them in one sentence ("first..., then..."), at most three, then name what comes after in a few words.
        - Don't end with a yes-or-no offer like "Want me to walk you through it?" Answering costs the user another press, so finish on something useful or just stop.
        - Write out anything a voice would misread: "for example" not "e.g.", "Command Option Escape" not "Cmd+Opt+Esc", "two and a half cups" not "2 1/2 cups", "ninety minutes" not "90 min", "twenty degrees" not "20°", "kilometers" not "km".
        - Never read code out symbol by symbol. Say the change in words, like "call sorted on the array".
        - No filler openers like "Great question" or "Sure".
        - The first screenshot is the screen with the cursor. "This" or "here" usually means something near the cursor.
        - Red lines or circles on their screen were drawn by the user to show you what they mean. When they marked something, "this" means the thing they marked.
        - Never say "screenshot" or "image". Talk about what's on their screen the way a person would.
        - If the question isn't about the screen, ignore the screenshots and don't mention them.
        - If you can't find what they're asking about on screen, say so. Don't guess.
        - Their words come from speech recognition and may be misheard. Answer what they most likely meant.
        - Earlier questions in this conversation also came with screenshots, which you saw and answered from, but they're removed from the history to save space. Your earlier answers were accurate descriptions of what was on screen then. Don't retract them because the old images are missing.

        Pointing:
        - You can point at one thing on their screen. A small pointer flies there while your answer is spoken.
        - End every reply with exactly one tag, after your spoken words. The tag is never read aloud.
        - To point, end with [POINT:x,y:label:screenN]. N is the screen number from that screen's label. The label names the thing in one to three words.
        - x and y are pixel coordinates in that screen's image, and the image's label gives its size. The origin 0,0 is the top-left corner. x grows to the right and y grows downward, so the bottom-right corner of a 1280x832 image is 1279,831.
        - Aim at the center of the thing.
        - Point when your answer is about one specific thing they can see, like a button, a menu, a setting, a cell, a line, or a message.
        - Otherwise end with [POINT:none]: when the question isn't about the screen, or when what they asked about isn't there.

        Examples:
        - "How do I make a new folder?" with Finder open on screen 1: "Click File in the menu bar, then New Folder. [POINT:211,12:File menu:screen1]"
        - "Where do I sign out?" with a browser on screen 2: "Click your profile picture in the top right corner of the browser on your other screen, then Sign Out. [POINT:1236,96:profile picture:screen2]"
        - "How many ounces are in a cup?": "Eight fluid ounces. [POINT:none]"
        - "Where's the export button?" with no export button anywhere on screen: "I don't see an export button on your screen. [POINT:none]"
        """

    private struct WireError: Decodable {
        struct Detail: Decodable {
            let type: String
            let message: String
        }

        let error: Detail
    }

    private struct WireEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stop_reason: String?
        }

        let type: String
        let delta: Delta?
        let error: WireError.Detail?
    }
}

nonisolated extension Claude.Question {
    init(text: String, screenshots: [Screenshot]) {
        self.init(
            images: screenshots.enumerated().map { index, shot in
                Image(label: shot.label(number: index + 1, of: screenshots.count), jpeg: shot.jpeg)
            },
            text: text
        )
    }
}

nonisolated extension Claude.Target {
    func appKitPoint(on shots: [Screenshot]) -> CGPoint? {
        guard case .point(let x, let y, _, let screen) = self, shots.indices.contains(screen - 1) else { return nil }
        return shots[screen - 1].appKitCentre(ofPixelX: x, y: y)
    }

    func callout(on shots: [Screenshot]) -> Callout? {
        guard case .point(_, _, let label, _) = self, let point = appKitPoint(on: shots) else { return nil }
        return Callout(point: point, label: label)
    }
}

nonisolated extension Journal.Point {
    init?(_ target: Claude.Target?) {
        guard case .point(let x, let y, let label, let screen)? = target else { return nil }
        self.init(label: label, screen: screen, x: x, y: y)
    }
}

final class Conversation {
    private let endpoint: Claude.Endpoint
    private let urlSession: URLSession
    private let journal: Journal?
    private var history: Claude.History

    init(endpoint: Claude.Endpoint, urlSession: URLSession, forgetAfter: Duration = Claude.History.idle, journal: Journal? = nil) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        self.journal = journal
        history = Claude.History(forgetAfter: forgetAfter)
    }

    func answer(_ question: Claude.Question, utterance: Int, writing: (String) -> Void) async throws(Claude.Failure) -> Claude.Said {
        let started = ContinuousClock.now
        let asked = Date.now
        let elapsed = { Int((started.duration(to: .now) / .milliseconds(1)).rounded()) }
        do throws(Claude.Failure) {
            let recalled = history.recalled(at: .now)
            let request = try Claude.request(question, after: recalled, to: endpoint)
            logger.notice("claude asking utterance=\(utterance) images=\(question.images.count) bytes=\(request.httpBody?.count ?? 0) history=\(recalled.count)")
            var reading = Claude.Answer()
            var written = ""
            var updates = 0
            var first = 0
            do {
                let (bytes, response) = try await urlSession.bytes(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    var body = Data()
                    for try await byte in bytes { body.append(byte) }
                    throw Claude.failure(status: status, body: body)
                }
                for try await line in bytes.lines {
                    try reading.read(line)
                    let shown = reading.shown
                    guard !shown.isEmpty, shown != written else { continue }
                    written = shown
                    if updates == 0 { first = elapsed() }
                    updates += 1
                    writing(shown)
                }
            } catch let failure as Claude.Failure {
                throw failure
            } catch {
                throw .transport(error.localizedDescription)
            }
            let said = try reading.finished()
            history.remember(Claude.Exchange(question: question.text, screens: question.images.count, answer: said.spoken), at: .now)
            await journal?.keep(
                asked: asked, question: question.text, screenshots: question.images.map(\.jpeg),
                answer: said.spoken, pointed: Journal.Point(said.target), recalled: recalled.count
            )
            let target = said.target?.logField ?? "missing"
            logger.notice("claude answered utterance=\(utterance) first=\(first) ms=\(elapsed()) chars=\(said.spoken.count) updates=\(updates) target=\(target, privacy: .public)")
            return said
        } catch {
            if Task.isCancelled {
                logger.notice("claude stopped utterance=\(utterance) ms=\(elapsed())")
            } else {
                logger.log(
                    level: error == .noAPIKey ? .default : .error,
                    "claude failed utterance=\(utterance) ms=\(elapsed()) \(error.logFields, privacy: .public)"
                )
            }
            throw error
        }
    }
}
