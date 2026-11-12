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

    static func request(_ question: Question, to endpoint: Endpoint) throws(Failure) -> URLRequest {
        guard let key = endpoint.key, !key.isEmpty else { throw .noAPIKey }
        var content: [[String: Any]] = []
        for image in question.images {
            content.append(["type": "text", "text": image.label])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image.jpeg.base64EncodedString()]])
        }
        content.append(["type": "text", "text": question.text])
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            "messages": [["role": "user", "content": content]],
            "stream": true,
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

        var shown: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

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

        func finished() throws(Failure) -> String {
            if stopReason == "refusal" { throw .declined }
            guard let stopReason else { throw .unanswered(status: 200, detail: "the stream ended without a stop_reason") }
            guard !shown.isEmpty else { throw .unanswered(status: 200, detail: "no text, stop_reason=\(stopReason)") }
            return shown
        }
    }

    private static let model = "claude-haiku-5-5"
    private static let version = "2026-10-21"
    private static let effort = "low"
    private static let maxTokens = 16000

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

final class Conversation {
    private let endpoint: Claude.Endpoint
    private let urlSession: URLSession

    init(endpoint: Claude.Endpoint, urlSession: URLSession) {
        self.endpoint = endpoint
        self.urlSession = urlSession
    }

    func answer(_ question: Claude.Question, utterance: Int, writing: (String) -> Void) async throws(Claude.Failure) -> String {
        let started = ContinuousClock.now
        let elapsed = { Int((started.duration(to: .now) / .milliseconds(1)).rounded()) }
        do throws(Claude.Failure) {
            let request = try Claude.request(question, to: endpoint)
            logger.notice("claude asking utterance=\(utterance) images=\(question.images.count) bytes=\(request.httpBody?.count ?? 0)")
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
            let text = try reading.finished()
            logger.notice("claude answered utterance=\(utterance) first=\(first) ms=\(elapsed()) chars=\(text.count) updates=\(updates)")
            return text
        } catch {
            logger.log(
                level: error == .noAPIKey ? .default : .error,
                "claude failed utterance=\(utterance) ms=\(elapsed()) \(error.logFields, privacy: .public)"
            )
            throw error
        }
    }
}
