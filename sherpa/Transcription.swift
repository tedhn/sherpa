import AVFoundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "transcription")

private let sampleRate = Int(SpeechConverter.format.sampleRate)

private let fallbackDelay: Duration = .milliseconds(2800)

private let drainLimit: Duration = .seconds(5)

typealias SpeechStream = AsyncStream<Data>

@Observable
final class Transcription {
    let number: Int

    var shown: AssemblyAI.Transcript.Shown { transcript.shown }

    var delivered: AssemblyAI.Final {
        get async {
            if let final = transcript.delivered { return final }
            return await withCheckedContinuation { awaitingDelivery.append($0) }
        }
    }

    func closed() async {
        await session?.value
    }

    private var transcript = AssemblyAI.Transcript()
    fileprivate let began = ContinuousClock.now
    @ObservationIgnored fileprivate var sentThrough: Duration = .zero
    @ObservationIgnored fileprivate var session: Task<Void, Never>?
    @ObservationIgnored private var awaitingDelivery: [CheckedContinuation<AssemblyAI.Final, Never>] = []

    fileprivate init(number: Int) {
        self.number = number
    }

    fileprivate func hear(_ turn: AssemblyAI.Turn) {
        announce(transcript.hear(turn, sentThrough: sentThrough), via: .endpoint)
    }

    fileprivate func finish() -> AssemblyAI.Transcript.Finish {
        let plan = transcript.finish()
        let lag = transcript.lastLag.map { String(Int($0 / .milliseconds(1))) } ?? "none"
        logger.notice("""
            transcription finishing session=\(self.number) plan=\(plan.rawValue, privacy: .public) \
            lag=\(lag, privacy: .public)
            """)
        return plan
    }

    fileprivate func expectEndpointAnswer() {
        transcript.expectEndpointAnswer()
    }

    fileprivate func terminated() {
        announce(transcript.settle(), via: .termination)
    }

    fileprivate func settle() {
        announce(transcript.settle(), via: .fallback)
    }

    fileprivate func fail(_ failure: AssemblyAI.Failure) {
        announce(transcript.fail(failure), via: .failure)
    }

    private enum Via: String { case endpoint, termination, fallback, failure }

    private func announce(_ final: AssemblyAI.Final?, via: Via) {
        guard let final else { return }
        let words = if case .heard(let text) = final { text } else { "" }
        logger.notice("""
            transcription final session=\(self.number) via=\(via.rawValue, privacy: .public) \
            after=\(self.began.duration(to: .now) / .seconds(1), format: .fixed(precision: 3)) text=\(words, privacy: .public)
            """)
        let waiting = awaitingDelivery
        awaitingDelivery = []
        for continuation in waiting { continuation.resume(returning: final) }
    }
}

final class Transcriber {
    struct Configuration {
        var key: String?
        var endpoints: AssemblyAI.Endpoints

        static var current: Configuration {
            let planted = (Bundle.main.object(forInfoDictionaryKey: "AssemblyAIAPIKey") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var configuration = Configuration(
                key: planted.isEmpty || planted.hasPrefix("$(") ? nil : planted,
                endpoints: .production
            )
            #if DEBUG
            let defaults = UserDefaults.standard
            // Read as strings, since url(forKey:) takes a plain string for a path.
            configuration.endpoints = AssemblyAI.Endpoints(
                token: defaults.string(forKey: "AssemblyAITokenURL").flatMap(URL.init(string:)) ?? configuration.endpoints.token,
                socket: defaults.string(forKey: "AssemblyAISocketURL").flatMap(URL.init(string:)) ?? configuration.endpoints.socket
            )
            if let key = defaults.string(forKey: "AssemblyAIAPIKey") { configuration.key = key }
            #endif
            return configuration
        }
    }

    private enum Stage: String { case minting, connecting, streaming, finishing, closing }

    private let configuration: Configuration
    private let urlSession = URLSession(configuration: .default)
    private var sessionCount = 0
    private var cachedToken: AssemblyAI.Token?

    init(configuration: Configuration = .current) {
        self.configuration = configuration
    }

    func transcribe(_ speech: SpeechStream) -> Transcription {
        sessionCount += 1
        let transcription = Transcription(number: sessionCount)
        transcription.session = Task { await run(transcription, speech) }
        return transcription
    }

    private func run(_ transcription: Transcription, _ speech: SpeechStream) async {
        let session = transcription.number
        let began = transcription.began
        var stage = Stage.minting
        var socket: URLSessionWebSocketTask?
        defer { socket?.cancel(with: .normalClosure, reason: nil) }
        defer { transcription.fail(.transport("the session ended without a final")) }
        do {
            var credential = try await token()
            stage = .connecting
            var task = open(credential.value)
            socket = task
            do {
                try await awaitBegin(on: task)
            } catch {
                let failure = AssemblyAI.Failure(error, closeCode: task.closeCode.rawValue, closeReason: task.closeReason)
                guard credential.reused, failure.isExpiredToken else { throw error }
                cachedToken = nil
                task.cancel(with: .normalClosure, reason: nil)
                logger.notice("transcription retry session=\(session) reason=expiredToken")
                stage = .minting
                credential = try await token()
                stage = .connecting
                task = open(credential.value)
                socket = task
                try await awaitBegin(on: task)
            }
            logger.notice("""
                transcription opened session=\(session) token=\(credential.reused ? "reused" : "minted", privacy: .public) \
                after=\(began.duration(to: .now) / .seconds(1), format: .fixed(precision: 3))
                """)

            stage = .streaming
            let live = task
            let listening = Task { try await listen(on: live, into: transcription) }
            let sent = try await speak(speech, on: live, counting: transcription)

            let drainEnds: ContinuousClock.Instant
            switch transcription.finish() {
            case .endpoint:
                stage = .finishing
                transcription.expectEndpointAnswer()
                try await send(.forceEndpoint, on: live, settlingAt: .now + fallbackDelay, for: transcription)
                stage = .closing
                try await live.send(.string(AssemblyAI.Control.terminate.rawValue))
                drainEnds = .now + drainLimit
            case .terminate:
                stage = .closing
                drainEnds = .now + drainLimit
                try await send(.terminate, on: live, settlingAt: drainEnds, for: transcription)
            }
            let serverSeconds = try await within(ContinuousClock.now.duration(to: drainEnds), cancelling: live) { try await listening.value }
            logger.notice("""
                transcription ended session=\(session) sent=\(sent.seconds, format: .fixed(precision: 3)) \
                frames=\(sent.frames) server=\(serverSeconds, format: .fixed(precision: 3)) \
                after=\(began.duration(to: .now) / .seconds(1), format: .fixed(precision: 3))
                """)
        } catch {
            if stage == .minting || stage == .connecting { cachedToken = nil }
            let failure = AssemblyAI.Failure(error, closeCode: socket?.closeCode.rawValue ?? 0, closeReason: socket?.closeReason)
            logger.log(
                level: failure == .noAPIKey ? .default : .error,
                "transcription failed session=\(session) stage=\(stage.rawValue, privacy: .public) \(failure.logFields, privacy: .public)"
            )
            transcription.fail(failure)
        }
    }

    private func send(
        _ control: AssemblyAI.Control,
        on socket: URLSessionWebSocketTask,
        settlingAt deadline: ContinuousClock.Instant,
        for transcription: Transcription
    ) async throws {
        let fallback = Task {
            try await Task.sleep(until: deadline)
            transcription.settle()
        }
        try await socket.send(.string(control.rawValue))
        _ = await transcription.delivered
        fallback.cancel()
    }

    private func open(_ token: String) -> URLSessionWebSocketTask {
        let task = urlSession.webSocketTask(with: configuration.endpoints.socketURL(token: token, sampleRate: sampleRate))
        task.resume()
        return task
    }

    private func token() async throws -> (value: String, reused: Bool) {
        if let cached = cachedToken, cached.isUsable(at: .now) { return (cached.value, true) }
        guard let key = configuration.key else { throw AssemblyAI.Failure.noAPIKey }
        let sentAt = ContinuousClock.now
        let (body, response) = try await urlSession.data(for: AssemblyAI.tokenRequest(key: key, at: configuration.endpoints.token))
        let minted = try AssemblyAI.token(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body, mintedAt: sentAt)
        cachedToken = minted
        return (minted.value, false)
    }
}

private func awaitBegin(on socket: URLSessionWebSocketTask) async throws {
    try await within(.seconds(5), cancelling: socket) {
        switch AssemblyAI.ServerEvent(json: try await socket.receive().payload) {
        case .began: return
        case .error(let code, let reason): throw AssemblyAI.Failure.serverError(code: code, reason: reason)
        default: throw AssemblyAI.Failure.transport("the first message was not Begin")
        }
    }
}

private func listen(on socket: URLSessionWebSocketTask, into transcription: Transcription) async throws -> Double {
    let session = transcription.number
    do {
        while true {
            switch AssemblyAI.ServerEvent(json: try await socket.receive().payload) {
            case .turn(let turn):
                logger.debug("heard session=\(session) turn=\(turn.order) formatted=\(turn.isFormatted) end=\(turn.endsTurn) text=\(turn.text, privacy: .public)")
                transcription.hear(turn)
            case .terminated(let audioSeconds):
                transcription.terminated()
                return audioSeconds
            case .error(let code, let reason):
                throw AssemblyAI.Failure.serverError(code: code, reason: reason)
            case .malformed(let type):
                logger.error("transcription ignored session=\(session) malformed=\(type ?? "not JSON", privacy: .public)")
            case .began, .ignored:
                break
            }
        }
    } catch {
        transcription.fail(AssemblyAI.Failure(error, closeCode: socket.closeCode.rawValue, closeReason: socket.closeReason))
        throw error
    }
}

private func speak(_ speech: SpeechStream, on socket: URLSessionWebSocketTask, counting transcription: Transcription) async throws -> (seconds: Double, frames: Int) {
    var framer = AssemblyAI.Framer(sampleRate: sampleRate)
    var bytes = 0
    var frames = 0
    var fed = 0
    var real = 0
    func send(_ frame: Data) async throws {
        try await socket.send(.data(frame))
        bytes += frame.count
        frames += 1
    }
    for await pcm in speech {
        fed += pcm.count
        for frame in framer.take(pcm) {
            try await send(frame)
            real += frame.count
            transcription.sentThrough = .milliseconds(real * 1000 / (sampleRate * 2))
        }
    }
    if let tail = framer.finish() {
        try await send(tail)
        transcription.sentThrough = .milliseconds(fed * 1000 / (sampleRate * 2))
    }
    return (Double(bytes) / Double(sampleRate * 2), frames)
}

// A timeout cancels the socket, because that, not task cancellation, is what
// makes the operation's pending receive() return so the group can finish.
private func within<T: Sendable>(
    _ limit: Duration,
    cancelling socket: URLSessionWebSocketTask,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw AssemblyAI.Failure.timedOut
        }
        defer { group.cancelAll() }
        do {
            return try await group.next()!
        } catch AssemblyAI.Failure.timedOut {
            socket.cancel(with: .goingAway, reason: nil)
            throw AssemblyAI.Failure.timedOut
        }
    }
}

private extension URLSessionWebSocketTask.Message {
    var payload: Data {
        switch self {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: Data()
        }
    }
}
