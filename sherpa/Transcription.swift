import AVFoundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "transcription")

private let sampleRate = Int(SpeechConverter.format.sampleRate)

private let drainLimit: Duration = .seconds(5)

typealias SpeechStream = AsyncStream<Data>

@Observable
final class Transcription {
    let number: Int

    fileprivate(set) var shown: AssemblyAI.Transcript.Shown = .hearing("")
    fileprivate(set) var reply: Claude.Reply?

    var delivered: AssemblyAI.Final {
        get async {
            if let final { return final }
            return await withCheckedContinuation { awaiting.append($0) }
        }
    }

    fileprivate let began = ContinuousClock.now
    @ObservationIgnored private var final: AssemblyAI.Final?
    @ObservationIgnored private var awaiting: [CheckedContinuation<AssemblyAI.Final, Never>] = []

    fileprivate init(number: Int) {
        self.number = number
    }

    fileprivate func deliver(_ final: AssemblyAI.Final) {
        self.final = final
        shown = .final(final)
        let waiting = awaiting
        awaiting = []
        for continuation in waiting { continuation.resume(returning: final) }
    }
}

final class Transcriber {
    struct Configuration {
        var key: String?
        var endpoints: AssemblyAI.Endpoints
        var limits = Dictation.Limits()
        var archive: Supabase.Project? = nil
        var screenshots: (@Sendable () async throws -> [Screenshot])? = nil
        var claude: Claude.Endpoint? = nil
        var voice: Voice.Endpoint? = nil
        var forgetAfter = Claude.History.idle

        static var current: Configuration {
            func planted(_ name: String) -> String? {
                let value = (Bundle.main.object(forInfoDictionaryKey: name) as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return value.isEmpty || value.hasPrefix("$(") ? nil : value
            }
            var configuration = Configuration(
                key: planted("AssemblyAIAPIKey"),
                endpoints: .production,
                archive: planted("SupabaseURL").flatMap(URL.init(string:)).flatMap { url in
                    planted("SupabasePublishableKey").map { Supabase.Project(url: url, key: $0) }
                },
                screenshots: Screenshot.everyDisplay,
                claude: Claude.Endpoint(url: Claude.Endpoint.production, key: planted("AnthropicAPIKey")),
                voice: Voice.Endpoint(url: Voice.Endpoint.production, key: planted("AssemblyAIAPIKey"))
            )
            #if DEBUG
            let defaults = UserDefaults.standard
            // Read as strings, since url(forKey:) takes a plain string for a path.
            configuration.endpoints = AssemblyAI.Endpoints(
                token: defaults.string(forKey: "AssemblyAITokenURL").flatMap(URL.init(string:)) ?? configuration.endpoints.token,
                socket: defaults.string(forKey: "AssemblyAISocketURL").flatMap(URL.init(string:)) ?? configuration.endpoints.socket
            )
            if let key = defaults.string(forKey: "AssemblyAIAPIKey") { configuration.key = key }
            if let idle = defaults.string(forKey: "AssemblyAIIdleSeconds").flatMap(Double.init) {
                configuration.limits.idle = .seconds(idle)
                configuration.limits.idleWithPanelOpen = .seconds(idle)
            }
            if let url = defaults.string(forKey: "SupabaseURL") {
                let key = defaults.string(forKey: "SupabasePublishableKey") ?? configuration.archive?.key
                configuration.archive = URL(string: url).flatMap { url in key.map { Supabase.Project(url: url, key: $0) } }
            }
            if let url = defaults.string(forKey: "AssemblyAIVoiceURL") {
                configuration.voice = URL(string: url).map { Voice.Endpoint(url: $0, key: configuration.key) }
            }
            if let url = defaults.string(forKey: "AnthropicURL") {
                let key = defaults.string(forKey: "AnthropicAPIKey") ?? configuration.claude?.key
                configuration.claude = URL(string: url).map { Claude.Endpoint(url: $0, key: key) }
            }
            #endif
            return configuration
        }
    }

    private let configuration: Configuration
    private let urlSession: URLSession
    private let tokens: Tokens
    private var dictation: Dictation
    private var records: [Int: Transcription] = [:]
    private var queued: [Int: SpeechStream] = [:]
    private var recorded: [Int: @Sendable () -> Data] = [:]
    private var partials: [Int: [Supabase.Partial]] = [:]
    private var sockets: [Int: Socket] = [:]
    private var screenshots: [Int: Task<[Screenshot]?, Never>] = [:]
    private var alarm: (at: ContinuousClock.Instant, task: Task<Void, Never>)?
    private let archive: Archive?
    private let conversation: Conversation?
    private let speaker: Speaker?

    init(configuration: Configuration = .current) {
        let urlSession = URLSession(configuration: .default)
        self.configuration = configuration
        self.urlSession = urlSession
        archive = configuration.archive.map { Archive(project: $0, urlSession: urlSession) }
        conversation = configuration.claude.map { Conversation(endpoint: $0, urlSession: urlSession, forgetAfter: configuration.forgetAfter) }
        speaker = configuration.voice.map { Speaker(endpoint: $0, urlSession: urlSession) }
        tokens = Tokens(key: configuration.key, url: configuration.endpoints.token, urlSession: urlSession)
        dictation = Dictation(limits: configuration.limits)
    }

    func warm() {
        handle(.panel(open: true))
    }

    func cool() {
        handle(.panel(open: false))
    }

    func press(_ speech: SpeechStream, recorded: @escaping @Sendable () -> Data) -> Transcription {
        let (press, effects) = dictation.press(at: .now)
        queued[press.hold] = speech
        self.recorded[press.hold] = recorded
        let record = records[press.utterance] ?? Transcription(number: press.utterance)
        records[press.utterance] = record
        run(effects)
        return record
    }

    func release() {
        if let capture = configuration.screenshots, let utterance = dictation.heldUtterance {
            screenshots[utterance] = Task { try? await capture() }
        }
        handle(.release)
    }

    func close() async {
        handle(.close)
        for socket in Array(sockets.values) { await socket.finished() }
    }

    private func handle(_ event: Dictation.Event) {
        run(dictation.handle(event, at: .now))
    }

    private func run(_ effects: [Dictation.Effect]) {
        for effect in effects { perform(effect) }
        for (number, record) in records {
            if let words = dictation.words(of: number) { record.shown = .hearing(words) }
        }
        rearm()
    }

    private func perform(_ effect: Dictation.Effect) {
        switch effect {
        case .connect(let session, let cause):
            logger.notice("transcription connecting session=\(session) cause=\(cause.rawValue, privacy: .public)")
            let socket = Socket(
                number: session,
                report: { [weak self] in self?.handle($0) },
                gone: { [weak self] in self?.sockets[session] = nil }
            )
            sockets[session] = socket
            socket.start(tokens: tokens, urlSession: urlSession, endpoints: configuration.endpoints)
        case .stream(let hold, let utterance, let session):
            if let speech = queued.removeValue(forKey: hold) { sockets[session]?.stream(speech, hold: hold, utterance: utterance) }
        case .finishing(let session, let utterance, let plan, let lag):
            let (name, wait) = switch plan {
            case .endpoint: ("endpoint", Duration.zero)
            case .wait(let wait): ("wait", wait)
            }
            logger.notice("""
                transcription finishing session=\(session) utterance=\(utterance) plan=\(name, privacy: .public) \
                wait=\(milliseconds(wait), privacy: .public) lag=\(lag.map(milliseconds) ?? "none", privacy: .public)
                """)
        case .endpoint(let session):
            sockets[session]?.endpoint()
        case .close(let session, let reason):
            sockets[session]?.close(reason)
        case .heard(let session, let utterance?, let turn):
            if let began = records[utterance]?.began {
                partials[utterance, default: []].append(Supabase.Partial(
                    sincePress: began.duration(to: .now),
                    turn: turn.order, end: turn.endsTurn, text: turn.text
                ))
            }
            logger.debug("""
                heard session=\(session) utterance=\(utterance) turn=\(turn.order) formatted=\(turn.isFormatted) \
                end=\(turn.endsTurn) text=\(turn.text, privacy: .public)
                """)
        case .heard(let session, nil, let turn):
            logger.notice("""
                transcription late session=\(session) turn=\(turn.order) formatted=\(turn.isFormatted) \
                end=\(turn.endsTurn) text=\(turn.text, privacy: .public)
                """)
        case .final(let session, let utterance, let final, let via):
            logger.notice("""
                transcription final session=\(number(session), privacy: .public) utterance=\(utterance) \
                via=\(via.rawValue, privacy: .public) after=\(self.after(utterance), privacy: .public) text=\(words(final), privacy: .public)
                """)
        case .deliver(let session, let utterance, let final, let via, let spans):
            logger.notice("""
                transcription delivered session=\(number(session), privacy: .public) utterance=\(utterance) \
                holds=\(spans.count) after=\(self.after(utterance), privacy: .public) text=\(words(final), privacy: .public)
                """)
            for span in spans { queued[span.hold] = nil }
            let record = records.removeValue(forKey: utterance)
            let heard = partials.removeValue(forKey: utterance) ?? []
            let recorders = spans.compactMap { recorded.removeValue(forKey: $0.hold) }
            if let archive, let record {
                let (now, instantNow) = (Date.now, ContinuousClock.now)
                let wall = { (instant: ContinuousClock.Instant) in now - instant.duration(to: instantNow) / .seconds(1) }
                let released = spans.last?.released
                archive.keep(Supabase.Utterance(
                    id: UUID(), started: wall(record.began),
                    ending: released.map { .released(at: wall($0), finalAfter: $0.duration(to: instantNow)) } ?? .midHold(deliveredAt: now),
                    holds: spans.count, final: final, via: via,
                    partials: heard, pcm: recorders.reduce(into: Data()) { $0.append($1()) }
                ), number: utterance)
            }
            let taken = screenshots.removeValue(forKey: utterance)
            if case .heard(let text) = final, let record, let conversation {
                record.reply = .asking
                Task {
                    let question = Claude.Question(text: text, screenshots: await handoff(taken, utterance: utterance))
                    do throws(Claude.Failure) {
                        let answer = try await conversation.answer(question, utterance: utterance) { record.reply = .answering($0) }
                        record.reply = .answered(answer)
                        speaker?.say(answer, utterance: utterance)
                    } catch {
                        record.reply = .failed(error)
                    }
                }
            } else if let taken {
                Task { _ = await handoff(taken, utterance: utterance) }
            }
            record?.deliver(final)
        }
    }

    private func rearm() {
        let deadline = dictation.deadline
        guard deadline != alarm?.at else { return }
        alarm?.task.cancel()
        alarm = deadline.map { at in
            (at, Task { [weak self] in
                try? await Task.sleep(until: at)
                guard !Task.isCancelled, let self else { return }
                alarm = nil
                handle(.tick)
            })
        }
    }

    private func after(_ utterance: Int) -> String {
        records[utterance].map { String(format: "%.3f", $0.began.duration(to: .now) / .seconds(1)) } ?? "none"
    }
}

private func handoff(_ taken: Task<[Screenshot]?, Never>?, utterance: Int) async -> [Screenshot] {
    guard let taken else { return [] }
    let shots = await taken.value
    logger.notice("transcription screenshots utterance=\(utterance) displays=\(shots.map { String($0.count) } ?? "none", privacy: .public)")
    return shots ?? []
}

private func milliseconds(_ duration: Duration) -> String {
    String(Int((duration / .milliseconds(1)).rounded()))
}

private func number(_ session: Int?) -> String {
    session.map(String.init) ?? "none"
}

private func words(_ final: AssemblyAI.Final) -> String {
    if case .heard(let text) = final { text } else { "" }
}

private final class Socket {
    private enum Stage: String { case minting, connecting, open, closing }

    private let number: Int
    private let report: (Dictation.Event) -> Void
    private let gone: () -> Void
    private let started = ContinuousClock.now
    private var stage = Stage.minting
    private var opened = false
    private var failed = false
    private var drainExpired = false
    private var task: URLSessionWebSocketTask?
    private var life: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var drain: Task<Void, Never>?
    private var bytes = 0
    private var frames = 0
    private var utterances: Set<Int> = []

    init(number: Int, report: @escaping (Dictation.Event) -> Void, gone: @escaping () -> Void) {
        self.number = number
        self.report = report
        self.gone = gone
    }

    func start(tokens: Tokens, urlSession: URLSession, endpoints: AssemblyAI.Endpoints) {
        life = Task {
            defer { gone() }
            do {
                var credential = try await tokens.current()
                try Task.checkCancellation()
                stage = .connecting
                var socket = open(credential.value, urlSession: urlSession, endpoints: endpoints)
                do {
                    try await awaitBegin(on: socket)
                } catch {
                    let failure = AssemblyAI.Failure(error, closeCode: socket.closeCode.rawValue, closeReason: socket.closeReason)
                    guard credential.reused, failure.isExpiredToken, !Task.isCancelled else { throw error }
                    tokens.forget()
                    socket.cancel(with: .normalClosure, reason: nil)
                    logger.notice("transcription retry session=\(self.number) reason=expiredToken")
                    stage = .minting
                    credential = try await tokens.current()
                    try Task.checkCancellation()
                    stage = .connecting
                    socket = open(credential.value, urlSession: urlSession, endpoints: endpoints)
                    try await awaitBegin(on: socket)
                }
                try Task.checkCancellation()
                logger.notice("""
                    transcription opened session=\(self.number) token=\(credential.reused ? "reused" : "minted", privacy: .public) \
                    after=\(self.started.duration(to: .now) / .seconds(1), format: .fixed(precision: 3))
                    """)
                stage = .open
                opened = true
                report(.began(session: number))
                let serverSeconds = try await listen(on: socket)
                guard stage == .closing else { throw AssemblyAI.Failure.transport("the server ended the session") }
                drain?.cancel()
                logger.notice("""
                    transcription ended session=\(self.number) sent=\(Double(self.bytes) / Double(sampleRate * 2), format: .fixed(precision: 3)) \
                    frames=\(self.frames) server=\(serverSeconds, format: .fixed(precision: 3)) \
                    after=\(self.started.duration(to: .now) / .seconds(1), format: .fixed(precision: 3)) utterances=\(self.utterances.count)
                    """)
            } catch {
                if !opened, stage != .closing { tokens.forget() }
                fail(error)
            }
        }
    }

    func stream(_ speech: SpeechStream, hold: Int, utterance: Int) {
        guard let task else { return }
        utterances.insert(utterance)
        pump = Task {
            var framer = AssemblyAI.Framer(sampleRate: sampleRate)
            do {
                for await pcm in speech {
                    for frame in framer.take(pcm) { try await send(frame, on: task) }
                }
                if let tail = framer.finish() { try await send(tail, on: task) }
                try Task.checkCancellation()
                report(.streamed(session: number, hold: hold))
            } catch is CancellationError {
            } catch {
                fail(error)
            }
        }
    }

    func endpoint() {
        guard let task else { return }
        Task {
            do { try await task.send(.string(AssemblyAI.Control.forceEndpoint.rawValue)) } catch { fail(error) }
        }
    }

    func close(_ reason: Dictation.Close) {
        guard stage != .closing else { return }
        logger.notice("transcription closing session=\(self.number) reason=\(reason.rawValue, privacy: .public)")
        let wasOpen = stage == .open
        stage = .closing
        pump?.cancel()
        guard wasOpen, let task else {
            life?.cancel()
            task?.cancel(with: .normalClosure, reason: nil)
            return
        }
        Task {
            do { try await task.send(.string(AssemblyAI.Control.terminate.rawValue)) } catch { fail(error) }
        }
        drain = Task {
            try? await Task.sleep(for: drainLimit)
            guard !Task.isCancelled else { return }
            drainExpired = true
            task.cancel(with: .goingAway, reason: nil)
        }
    }

    func finished() async {
        await life?.value
    }

    private func open(_ token: String, urlSession: URLSession, endpoints: AssemblyAI.Endpoints) -> URLSessionWebSocketTask {
        let socket = urlSession.webSocketTask(with: endpoints.socketURL(token: token, sampleRate: sampleRate))
        socket.resume()
        task = socket
        return socket
    }

    private func send(_ frame: Data, on task: URLSessionWebSocketTask) async throws {
        try Task.checkCancellation()
        try await task.send(.data(frame))
        bytes += frame.count
        frames += 1
        report(.sent(session: number, audio: .microseconds(frame.count * 1_000_000 / (sampleRate * 2))))
    }

    private func listen(on socket: URLSessionWebSocketTask) async throws -> Double {
        while true {
            switch AssemblyAI.ServerEvent(json: try await socket.receive().payload) {
            case .turn(let turn):
                report(.heard(session: number, turn))
            case .terminated(let audioSeconds):
                return audioSeconds
            case .error(let code, let reason):
                throw AssemblyAI.Failure.serverError(code: code, reason: reason)
            case .malformed(let type):
                logger.error("transcription ignored session=\(self.number) malformed=\(type ?? "not JSON", privacy: .public)")
            case .began, .ignored:
                break
            }
        }
    }

    private func fail(_ error: any Error) {
        guard !failed else { return }
        failed = true
        let failure = AssemblyAI.Failure(
            drainExpired ? AssemblyAI.Failure.timedOut : error,
            closeCode: task?.closeCode.rawValue ?? 0, closeReason: task?.closeReason
        )
        pump?.cancel()
        drain?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        guard opened || stage != .closing else { return }
        logger.log(
            level: failure == .noAPIKey ? .default : .error,
            "transcription failed session=\(self.number) stage=\(self.stage.rawValue, privacy: .public) \(failure.logFields, privacy: .public)"
        )
        if stage != .closing { report(.failed(session: number, failure)) }
    }
}

private final class Tokens {
    private let key: String?
    private let url: URL
    private let urlSession: URLSession
    private var cached: AssemblyAI.Token?

    init(key: String?, url: URL, urlSession: URLSession) {
        self.key = key
        self.url = url
        self.urlSession = urlSession
    }

    func current() async throws -> (value: String, reused: Bool) {
        if let cached, cached.isUsable(at: .now) { return (cached.value, true) }
        guard let key else { throw AssemblyAI.Failure.noAPIKey }
        let sentAt = ContinuousClock.now
        let (body, response) = try await urlSession.data(for: AssemblyAI.tokenRequest(key: key, at: url))
        let minted = try AssemblyAI.token(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body, mintedAt: sentAt)
        cached = minted
        return (minted.value, false)
    }

    func forget() {
        cached = nil
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
