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
                // The hold ends an utterance, not a pause. With the defaults the server ended
                // "Open the." on its own between two merged holds, before any ForceEndpoint.
                URLQueryItem(name: "end_of_turn_confidence_threshold", value: "1"),
                URLQueryItem(name: "min_end_of_turn_silence_when_confident", value: "10000"),
                URLQueryItem(name: "max_turn_silence", value: "10000"),
                URLQueryItem(name: "token", value: token),
            ]
            return components.url!
        }
    }

    static let tokenLifetime: Duration = .seconds(480)

    // The lifetime only limits when a token can open a session, and an open
    // session outlives it. The margin keeps a token from expiring mid-connect.
    struct Token: Equatable, Sendable {
        let value: String
        let expires: ContinuousClock.Instant

        func isUsable(at now: ContinuousClock.Instant) -> Bool {
            expires - now > .seconds(30)
        }
    }

    static func tokenRequest(key: String, at url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"product":"streaming","expires_in_seconds":\#(tokenLifetime.components.seconds)}"#.utf8)
        return request
    }

    // `mintedAt` is when the request was sent, so the expiry errs early.
    static func token(status: Int, body: Data, mintedAt: ContinuousClock.Instant) throws(Failure) -> Token {
        guard status == 200, let reply = try? JSONDecoder().decode(TokenReply.self, from: body) else {
            throw .tokenRefused(status: status, detail: String(decoding: body.prefix(200), as: UTF8.self))
        }
        return Token(value: reply.token, expires: mintedAt + tokenLifetime)
    }

    // Each Turn supersedes the previous one with the same `order`: render the
    // latest, never append.
    struct Turn: Equatable, Sendable {
        let order: Int
        let text: String
        let isFormatted: Bool
        let endsTurn: Bool
        let audioEnd: Duration?

        enum Stage: Comparable { case partial, unformattedEnd, formattedEnd }

        var stage: Stage { endsTurn ? (isFormatted ? .formattedEnd : .unformattedEnd) : .partial }

        var canAnswerEndpoint: Bool {
            isFormatted || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
                    endsTurn: turn.end_of_turn,
                    audioEnd: turn.words?.last.map { .milliseconds($0.end) }
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
        case forceEndpoint = #"{"type":"ForceEndpoint"}"#
        case terminate = #"{"type":"Terminate"}"#
    }

    enum Final: Equatable, Sendable {
        case heard(String)
        case silence
        case failed(Failure)
    }

    // One utterance's words, keyed by turn order.
    struct Transcript: Equatable, Sendable {
        enum Shown: Equatable, Sendable {
            case hearing(String)
            case final(Final)
        }

        private var turns: [Int: Turn] = [:]

        init() {}

        var text: String {
            turns.sorted { $0.key < $1.key }
                .map { $0.value.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var final: Final { text.isEmpty ? .silence : .heard(text) }

        mutating func hear(_ turn: Turn) {
            if turns[turn.order].map({ $0.stage <= turn.stage }) ?? true {
                turns[turn.order] = turn
            }
        }
    }

    // What one socket has sent, and what the server's answers on it mean. The audio
    // clock counts every byte sent, padding included, because word end times use that
    // same timeline.
    struct Ledger: Equatable, Sendable {
        // Live partials trailed the sent audio by a median 300 ms, p90 380 ms, max 740 ms;
        // a queued backlog by over 2000 ms.
        static let caughtUpLag: Duration = .milliseconds(600)
        static let answerLimit: Duration = .milliseconds(2800)

        struct Outstanding: Equatable, Sendable {
            let floor: Int
            let sentAt: ContinuousClock.Instant
        }

        private struct Latest: Equatable, Sendable {
            let order: Int
            let ended: Bool
        }

        private(set) var clock: Duration = .zero
        private(set) var lastLag: Duration?
        private(set) var outstanding: Outstanding?
        private var wanted: ContinuousClock.Instant?
        // A worst-case bound on the audio the server holds unprocessed, as of `asOf`: each
        // frame adds its length, the server drains at least real time, and a word end shows
        // how far it has got.
        private var backlog: Duration = .zero
        private var asOf: ContinuousClock.Instant
        private var latest: Latest?

        init(began: ContinuousClock.Instant) {
            asOf = began
        }

        // Turn orders count up across the whole session, so a turn this socket has already
        // carried can never be the first of a new utterance.
        var nextOrder: Int { latest.map { $0.order + 1 } ?? 0 }

        mutating func sent(_ audio: Duration, at now: ContinuousClock.Instant) {
            backlog = worst(at: now) + audio
            asOf = now
            clock += audio
        }

        // True when the turn answers the outstanding ForceEndpoint.
        mutating func hear(_ turn: Turn, at now: ContinuousClock.Instant) -> Bool {
            if let end = turn.audioEnd {
                lastLag = clock - end
                backlog = max(.zero, min(worst(at: now), clock - end))
                asOf = now
            }
            switch latest {
            case let known? where known.order > turn.order:
                break
            case let known? where known.order == turn.order:
                latest = Latest(order: known.order, ended: known.ended || turn.endsTurn)
            default:
                latest = Latest(order: turn.order, ended: turn.endsTurn)
            }
            // Measured: the server answers ForceEndpoint with one end_of_turn at or above the
            // turn that was open when it was sent, an empty one after silence.
            guard let floor = outstanding?.floor, turn.endsTurn, turn.order >= floor, turn.canAnswerEndpoint
            else { return false }
            outstanding = nil
            return true
        }

        mutating func want(notBefore instant: ContinuousClock.Instant) { wanted = instant }

        mutating func unwant() { wanted = nil }

        // AssemblyAI applies ForceEndpoint where its processing has reached, not after audio
        // still queued, so it ends the wrong turn while the server is behind.
        var caughtUp: ContinuousClock.Instant { asOf + max(.zero, backlog - Self.caughtUpLag) }

        var endpointDue: ContinuousClock.Instant? {
            guard let wanted, outstanding == nil else { return nil }
            return max(wanted, caughtUp)
        }

        // One ForceEndpoint outstanding at a time, so no answer is counted against the wrong one.
        mutating func fire(at now: ContinuousClock.Instant) -> Bool {
            guard let due = endpointDue, due <= now else { return false }
            wanted = nil
            outstanding = Outstanding(floor: latest.map { $0.ended ? $0.order + 1 : $0.order } ?? 0, sentAt: now)
            return true
        }

        var answerDue: ContinuousClock.Instant? { outstanding.map { $0.sentAt + Self.answerLimit } }

        private func worst(at now: ContinuousClock.Instant) -> Duration {
            max(.zero, backlog - asOf.duration(to: now))
        }
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

        var isExpiredToken: Bool {
            guard case .serverError(code: 1008, let reason) = self else { return false }
            return reason.contains("Signature has expired")
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
        let words: [WireWord]?
    }
    private struct WireWord: Decodable { let end: Int }
    private struct WireError: Decodable {
        let error_code: Int?
        let error: String
    }
    private struct WireTermination: Decodable { let audio_duration_seconds: Double }
}
