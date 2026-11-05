import Foundation

nonisolated enum AssemblyAI {
    struct Endpoints: Equatable, Sendable {
        let token: URL
        let socket: URL

        static let production = Endpoints(
            token: URL(string: "https://token.assemblyai.com/v1/token")!,
            socket: URL(string: "wss://streaming.assemblyai.com/v3/ws")!
        )

        func socketURL(token: String, sampleRate: Int) -> URL {
            var components = URLComponents(url: socket, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "sample_rate", value: String(sampleRate)),
                URLQueryItem(name: "encoding", value: "pcm_s16le"),
                URLQueryItem(name: "format_turns", value: "true"),
                URLQueryItem(name: "speech_model", value: "universal-streaming-english"),
                URLQueryItem(name: "token", value: token),
            ]
            return components.url!
        }
    }

    static func tokenRequest(key: String, at url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"product":"streaming","expires_in_seconds":480}"#.utf8)
        return request
    }

    static func token(status: Int, body: Data) throws(Failure) -> String {
        guard status == 200, let reply = try? JSONDecoder().decode(TokenReply.self, from: body) else {
            throw .tokenRefused(status: status, detail: String(decoding: body.prefix(200), as: UTF8.self))
        }
        return reply.token
    }

    // Each Turn supersedes the previous one with the same `order`: render the
    // latest, never append.
    struct Turn: Equatable, Sendable {
        let order: Int
        let text: String
        let isFormatted: Bool
        let endsTurn: Bool
    }

    enum ServerEvent: Equatable, Sendable {
        case began
        case turn(Turn)
        case terminated(audioSeconds: Double)
        // The server sends its refusal as text before it closes, and the close
        // code can still read 0 afterwards, so this is the only place the reason is.
        case error(code: Int, reason: String)
        case ignored(type: String)
        case malformed(type: String?)

        init(json: Data) {
            let decoder = JSONDecoder()
            guard let type = try? decoder.decode(Envelope.self, from: json).type else {
                self = .malformed(type: nil)
                return
            }
            switch type {
            case "Begin":
                self = .began
            case "Turn":
                guard let turn = try? decoder.decode(WireTurn.self, from: json) else {
                    self = .malformed(type: type)
                    return
                }
                self = .turn(Turn(
                    order: turn.turn_order,
                    text: turn.transcript,
                    isFormatted: turn.turn_is_formatted,
                    endsTurn: turn.end_of_turn
                ))
            case "Termination":
                guard let termination = try? decoder.decode(WireTermination.self, from: json) else {
                    self = .malformed(type: type)
                    return
                }
                self = .terminated(audioSeconds: termination.audio_duration_seconds)
            case "Error":
                guard let error = try? decoder.decode(WireError.self, from: json) else {
                    self = .malformed(type: type)
                    return
                }
                self = .error(code: error.error_code ?? 0, reason: error.error)
            default:
                self = .ignored(type: type)
            }
        }
    }

    enum Control: String {
        case terminate = #"{"type":"Terminate"}"#
    }

    // The server documents 20 to 1000 ms; the node SDK says under 50 ms is
    // rejected, so 50 ms is the floor.
    struct Framer: Sendable {
        private let shortest: Int
        private let longest: Int
        private var pending = Data()

        init(sampleRate: Int) {
            longest = sampleRate * 2
            shortest = longest / 20
        }

        mutating func take(_ pcm: Data) -> [Data] {
            pending.append(pcm)
            var frames: [Data] = []
            while pending.count >= shortest {
                let size = min(pending.count, longest) & ~1
                frames.append(Data(pending.prefix(size)))
                pending = Data(pending.dropFirst(size))
            }
            return frames
        }

        mutating func finish() -> Data? {
            guard !pending.isEmpty else { return nil }
            defer { pending = Data() }
            return pending + Data(count: shortest - pending.count)
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case noAPIKey
        case tokenRefused(status: Int, detail: String)
        case serverError(code: Int, reason: String)
        case timedOut
        case transport(String)

        // A send and a receive both throw when the server closes, and only the
        // close code says why, so it outranks the error. A Failure outranks the
        // close code, because a deadline's own cancel sets one too.
        init(_ error: any Error, closeCode: Int, closeReason: Data?) {
            if let failure = error as? Failure {
                self = failure
            } else if closeCode != 0 {
                self = .serverError(code: closeCode, reason: closeReason.map { String(decoding: $0, as: UTF8.self) } ?? "")
            } else {
                self = .transport(error.localizedDescription)
            }
        }

        var logFields: String {
            switch self {
            case .noAPIKey: "reason=noAPIKey"
            case .tokenRefused(let status, let detail): "reason=tokenRefused status=\(status) detail=\(detail)"
            case .serverError(let code, let reason): "reason=serverError code=\(code) detail=\(reason)"
            case .timedOut: "reason=timedOut"
            case .transport(let detail): "reason=transport detail=\(detail)"
            }
        }
    }

    private struct TokenReply: Decodable { let token: String }
    private struct Envelope: Decodable { let type: String }
    private struct WireTurn: Decodable {
        let turn_order: Int
        let turn_is_formatted: Bool
        let end_of_turn: Bool
        let transcript: String
    }
    private struct WireError: Decodable {
        let error_code: Int?
        let error: String
    }
    private struct WireTermination: Decodable { let audio_duration_seconds: Double }
}
