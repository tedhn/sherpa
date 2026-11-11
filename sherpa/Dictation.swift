import Foundation

// Every decision about holds, utterances and AssemblyAI sessions, held in one value. Time
// comes in as an argument and effects go out as values, so a check can drive any
// interleaving with literal instants and no socket.
//
// One socket is current at a time. An utterance's ForceEndpoint goes only after its merge
// window, so none falls between merged holds and the answer ends the utterance. A new
// utterance streams only after the previous owner of the socket is answered and delivered,
// so no server turn holds two utterances' audio. Delivery is the only way an utterance
// leaves `live`, so each is delivered once. Deadlines are derived, never stored: every
// event first runs whatever fell due.
nonisolated struct Dictation: Sendable {
    typealias Instant = ContinuousClock.Instant

    struct Limits: Equatable, Sendable {
        // ForceEndpoint waits this long after the last release too, so no delivery comes sooner.
        var merge: Duration = .seconds(1)
        var idle: Duration = .seconds(30)
        // An open panel keeps a billed session open, so it closes too, just later.
        var idleWithPanelOpen: Duration = .seconds(120)
    }

    struct Press: Equatable, Sendable {
        let hold: Int
        let utterance: Int
    }

    struct Span: Equatable, Sendable {
        let hold: Int
        let pressed: Instant
        var released: Instant?
    }

    enum Event: Equatable, Sendable {
        case panel(open: Bool)
        case release
        case began(session: Int)
        case sent(session: Int, audio: Duration)
        // A hold's speech ended and its padded tail frame went out.
        case streamed(session: Int, hold: Int)
        case heard(session: Int, AssemblyAI.Turn)
        case failed(session: Int, AssemblyAI.Failure)
        case tick
        case close
    }

    enum Effect: Equatable, Sendable {
        case connect(session: Int, cause: Cause)
        case stream(hold: Int, utterance: Int, session: Int)
        case finishing(session: Int, utterance: Int, plan: Plan, lag: Duration?)
        case endpoint(session: Int)
        case close(session: Int, reason: Close)
        // No utterance means the turn came late: from a closed socket or below the owner's first turn.
        case heard(session: Int, utterance: Int?, AssemblyAI.Turn)
        case final(session: Int?, utterance: Int, AssemblyAI.Final, via: Via)
        case deliver(session: Int?, utterance: Int, AssemblyAI.Final, via: Via, spans: [Span])
    }

    enum Cause: String, Sendable { case panel, press, carry }
    enum Close: String, Sendable { case idle, quit, retire, stale }
    enum Via: String, Sendable { case endpoint, fallback, failure }

    enum Plan: Equatable, Sendable {
        case endpoint
        case wait(Duration)
    }

    // Free accounts may open 5 sessions a minute. Warming waits once 3 opened in the last
    // minute, so a press always finds one left.
    private static let warmConnects = 3
    private static let connectWindow: Duration = .seconds(60)

    let limits: Limits

    private var panelOpen = false
    private var line = Line.down
    // Undelivered utterances, oldest first. Only the socket's owner has sent audio.
    private var live: [Utterance] = []
    // Since when no hold has been down. Nil while one is.
    private var quietSince: Instant?
    private var connects: [Instant] = []
    private var sessions = 0
    private var utterances = 0
    private var holds = 0

    private enum Line: Equatable {
        case down
        case connecting(session: Int)
        case up(Socket)

        var session: Int? {
            switch self {
            case .down: nil
            case .connecting(let session): session
            case .up(let socket): socket.session
            }
        }
    }

    private struct Socket: Equatable {
        let session: Int
        var ledger: AssemblyAI.Ledger
        var owner: Int?
        // The owner's first turn order. A lower one belongs to an utterance already delivered.
        var from = 0
        var streaming: Int?
    }

    private struct Utterance: Equatable {
        enum Phase: Equatable {
            case held
            case finishing(released: Instant)
        }

        let number: Int
        var transcript = AssemblyAI.Transcript()
        var holds: [Hold]
        var phase: Phase
        // Set when its first hold streams. Nil while every hold is still queued.
        var session: Int?
    }

    private struct Hold: Equatable {
        enum Stage: Equatable { case queued, streaming, sent }
        var span: Span
        var stage: Stage
    }

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    // A press joins the newest utterance when it comes within the merge window of that
    // utterance's release. Otherwise it starts a new one.
    mutating func press(at now: Instant) -> (Press, [Effect]) {
        var effects = expire(at: now)
        quietSince = nil
        holds += 1
        let hold = Hold(span: Span(hold: holds, pressed: now), stage: .queued)
        let utterance: Int
        if let index = joinable(at: now) {
            live[index].phase = .held
            live[index].holds.append(hold)
            if case .up(var socket) = line, socket.owner == live[index].number {
                socket.ledger.unwant()
                line = .up(socket)
            }
            utterance = live[index].number
        } else {
            utterances += 1
            live.append(Utterance(number: utterances, holds: [hold], phase: .held))
            utterance = utterances
        }
        if line == .down { effects += connect(.press, at: now) }
        effects += advance()
        return (Press(hold: holds, utterance: utterance), effects)
    }

    // Every event first runs whatever fell due, so the shell's timer only has to fire some
    // time after `deadline`.
    mutating func handle(_ event: Event, at now: Instant) -> [Effect] {
        var effects = expire(at: now)
        switch event {
        case .panel(let open):
            panelOpen = open
            if !holding { quietSince = now }
            if open, line == .down { effects += warm(at: now) }
        case .release:
            if let index = live.lastIndex(where: { $0.phase == .held }) {
                live[index].phase = .finishing(released: now)
                live[index].holds[live[index].holds.count - 1].span.released = now
                effects += finish(live[index].number, at: now)
            }
            if !holding { quietSince = now }
        case .began(let session):
            switch line {
            case .connecting(session):
                line = .up(Socket(session: session, ledger: AssemblyAI.Ledger(began: now)))
                effects += advance()
            case .up(let socket) where socket.session == session:
                break
            default:
                effects.append(.close(session: session, reason: .stale))
            }
        case .sent(let session, let audio):
            guard case .up(var socket) = line, socket.session == session else { break }
            socket.ledger.sent(audio, at: now)
            line = .up(socket)
        case .streamed(let session, let hold):
            guard case .up(var socket) = line, socket.session == session, socket.streaming == hold,
                  let index = live.firstIndex(where: { $0.number == socket.owner }),
                  let stage = live[index].holds.firstIndex(where: { $0.span.hold == hold })
            else { break }
            live[index].holds[stage].stage = .sent
            socket.streaming = nil
            line = .up(socket)
            effects += finish(live[index].number, at: now)
            effects += advance()
        case .heard(let session, let turn):
            effects += hear(turn, on: session, at: now)
        case .failed(let session, let failure):
            switch line {
            case .connecting(session):
                effects += lose(session, failure, wasOpen: false, at: now)
            case .up(let socket) where socket.session == session:
                effects += lose(session, failure, wasOpen: true, at: now)
            default:
                break
            }
        case .tick:
            break
        case .close:
            let session = line.session
            while !live.isEmpty { effects += fail(0, .transport("Sherpa closed the session"), on: session) }
            if let session { effects.append(.close(session: session, reason: .quit)) }
            line = .down
        }
        return effects
    }

    // The next instant something falls due. The shell sleeps until then and sends `.tick`.
    var deadline: Instant? {
        var due: [Instant] = []
        if case .up(let socket) = line {
            due += [socket.ledger.endpointDue, socket.ledger.answerDue].compactMap { $0 }
        }
        if let idleAt { due.append(idleAt) }
        return due.min()
    }

    // Nil once delivered, when the record shows the final instead.
    func words(of utterance: Int) -> String? {
        live.first { $0.number == utterance }?.transcript.text
    }

    var heldUtterance: Int? { live.last { $0.phase == .held }?.number }

    private var holding: Bool { live.contains { $0.phase == .held } }

    private var idleAt: Instant? {
        guard line != .down, live.isEmpty, let quietSince else { return nil }
        return quietSince + (panelOpen ? limits.idleWithPanelOpen : limits.idle)
    }

    private mutating func expire(at now: Instant) -> [Effect] {
        var effects: [Effect] = []
        if case .up(var socket) = line, socket.ledger.fire(at: now) {
            line = .up(socket)
            effects.append(.endpoint(session: socket.session))
        }
        if case .up(let socket) = line, let due = socket.ledger.answerDue, due <= now {
            effects += retire(socket, at: now)
        }
        if let idleAt, idleAt <= now, let session = line.session {
            effects.append(.close(session: session, reason: .idle))
            line = .down
        }
        return effects
    }

    // No answer in time means a late one would be counted against the next ForceEndpoint,
    // so the socket goes and its owner delivers the words so far.
    private mutating func retire(_ socket: Socket, at now: Instant) -> [Effect] {
        var effects: [Effect] = []
        if let index = live.firstIndex(where: { $0.number == socket.owner }) {
            effects.append(.final(session: socket.session, utterance: live[index].number, live[index].transcript.final, via: .fallback))
            effects.append(deliver(index, via: .fallback))
        }
        effects.append(.close(session: socket.session, reason: .retire))
        line = .down
        if !live.isEmpty {
            effects += connect(.carry, at: now)
        } else if panelOpen {
            effects += warm(at: now)
        }
        return effects
    }

    // A socket failed or the server closed it. Utterances that sent audio on it end now.
    // Ones still queued move to a new socket, unless it never opened: then they fail too, so
    // a refused key cannot loop.
    private mutating func lose(_ session: Int, _ failure: AssemblyAI.Failure, wasOpen: Bool, at now: Instant) -> [Effect] {
        line = .down
        var effects: [Effect] = []
        var index = 0
        while index < live.count {
            if wasOpen, live[index].session == nil {
                index += 1
            } else {
                effects += fail(index, failure, on: session)
            }
        }
        if !live.isEmpty { effects += connect(.carry, at: now) }
        return effects
    }

    private mutating func hear(_ turn: AssemblyAI.Turn, on session: Int, at now: Instant) -> [Effect] {
        guard case .up(var socket) = line, socket.session == session else {
            return [.heard(session: session, utterance: nil, turn)]
        }
        let answered = socket.ledger.hear(turn, at: now)
        let owner = turn.order >= socket.from ? live.firstIndex { $0.number == socket.owner } : nil
        var effects: [Effect] = [.heard(session: session, utterance: owner.map { live[$0].number }, turn)]
        if let owner {
            live[owner].transcript.hear(turn)
            if answered {
                effects.append(.final(session: session, utterance: live[owner].number, live[owner].transcript.final, via: .endpoint))
                effects.append(deliver(owner, via: .endpoint))
            }
        }
        if socket.ledger.fire(at: now) { effects.append(.endpoint(session: session)) }
        line = .up(socket)
        return effects + advance()
    }

    // The owner's release and audio are both done: ForceEndpoint once the merge window has
    // passed with no press and the server has caught up. The plan says how much longer than
    // the window the server needs.
    private mutating func finish(_ utterance: Int, at now: Instant) -> [Effect] {
        guard case .up(var socket) = line, socket.owner == utterance,
              let index = live.firstIndex(where: { $0.number == utterance }),
              case .finishing(let released) = live[index].phase,
              live[index].holds.allSatisfy({ $0.stage == .sent })
        else { return [] }
        let windowEnds = released + limits.merge
        socket.ledger.want(notBefore: windowEnds)
        let fired = socket.ledger.fire(at: now)
        line = .up(socket)
        let beyond = windowEnds.duration(to: socket.ledger.caughtUp)
        let plan = beyond > .zero ? Plan.wait(beyond) : .endpoint
        let finishing = Effect.finishing(session: socket.session, utterance: utterance, plan: plan, lag: socket.ledger.lastLag)
        return fired ? [finishing, .endpoint(session: socket.session)] : [finishing]
    }

    // Starts the oldest queued hold. A new utterance takes the socket only once the previous
    // owner is delivered, which it is only after its last ForceEndpoint was answered or its
    // socket went.
    private mutating func advance() -> [Effect] {
        guard case .up(var socket) = line, socket.streaming == nil,
              let index = live.firstIndex(where: { $0.holds.contains { $0.stage == .queued } }),
              let hold = live[index].holds.firstIndex(where: { $0.stage == .queued })
        else { return [] }
        if live[index].number != socket.owner {
            guard !live.contains(where: { $0.number == socket.owner }) else { return [] }
            socket.owner = live[index].number
            socket.from = socket.ledger.nextOrder
            live[index].session = socket.session
        }
        live[index].holds[hold].stage = .streaming
        socket.streaming = live[index].holds[hold].span.hold
        line = .up(socket)
        return [.stream(hold: live[index].holds[hold].span.hold, utterance: live[index].number, session: socket.session)]
    }

    private mutating func fail(_ index: Int, _ failure: AssemblyAI.Failure, on session: Int?) -> [Effect] {
        let final = Effect.final(session: live[index].session ?? session, utterance: live[index].number, .failed(failure), via: .failure)
        return [final, deliver(index, .failed(failure), via: .failure, on: session)]
    }

    // The only place an utterance leaves `live`.
    private mutating func deliver(_ index: Int, _ final: AssemblyAI.Final? = nil, via: Via, on session: Int? = nil) -> Effect {
        let utterance = live.remove(at: index)
        return .deliver(
            session: utterance.session ?? session, utterance: utterance.number,
            final ?? utterance.transcript.final, via: via, spans: utterance.holds.map(\.span)
        )
    }

    private func joinable(at now: Instant) -> Int? {
        guard let index = live.indices.last, case .finishing(let released) = live[index].phase,
              released + limits.merge > now
        else { return nil }
        return index
    }

    private mutating func warm(at now: Instant) -> [Effect] {
        connects.removeAll { $0 + Self.connectWindow <= now }
        guard connects.count < Self.warmConnects else { return [] }
        return connect(.panel, at: now)
    }

    private mutating func connect(_ cause: Cause, at now: Instant) -> [Effect] {
        connects.removeAll { $0 + Self.connectWindow <= now }
        connects.append(now)
        sessions += 1
        line = .connecting(session: sessions)
        return [.connect(session: sessions, cause: cause)]
    }
}
