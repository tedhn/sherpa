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
        ]
        // A non-streaming reply sends nothing until it is whole, so the default 60 s could cut off a long answer.
        var request = URLRequest(url: endpoint.url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    static func answer(status: Int, body: Data) throws(Failure) -> String {
        let excerpt = String(decoding: body.prefix(200), as: UTF8.self)
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode(WireError.self, from: body)).map { "\($0.error.type): \($0.error.message)" } ?? excerpt
            switch status {
            case 401, 403: throw .keyRefused(status: status, detail: detail)
            case 429, 500...599: throw .busy(status: status, detail: detail)
            default: throw .unanswered(status: status, detail: detail)
            }
        }
        guard let message = try? JSONDecoder().decode(WireMessage.self, from: body) else {
            throw .unanswered(status: status, detail: excerpt)
        }
        if message.stop_reason == "refusal" { throw .declined }
        let text = message.content.filter { $0.type == "text" }.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw .unanswered(status: status, detail: "no text, stop_reason=\(message.stop_reason ?? "none")")
        }
        return text
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

    private struct WireMessage: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }

        let content: [Block]
        let stop_reason: String?
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

    func answer(_ question: Claude.Question, utterance: Int) async throws(Claude.Failure) -> String {
        let started = ContinuousClock.now
        let elapsed = { Int((started.duration(to: .now) / .milliseconds(1)).rounded()) }
        do throws(Claude.Failure) {
            let request = try Claude.request(question, to: endpoint)
            logger.notice("claude asking utterance=\(utterance) images=\(question.images.count) bytes=\(request.httpBody?.count ?? 0)")
            let (body, response): (Data, URLResponse)
            do {
                (body, response) = try await urlSession.data(for: request)
            } catch {
                throw .transport(error.localizedDescription)
            }
            let text = try Claude.answer(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
            logger.notice("claude answered utterance=\(utterance) ms=\(elapsed()) chars=\(text.count)")
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
