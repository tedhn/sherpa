import Foundation
import os

private let marker = Logger(subsystem: "my.rooftop.sherpa", category: "transcription")

nonisolated final class LogTail: @unchecked Sendable {
    struct Line {
        let text: String
        let at: Date
    }

    private let lock = NSLock()
    private var messages: [Line] = []
    private let process = Process()

    init() {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "ndjson", "--predicate",
            "processIdentifier == \(getpid()) AND subsystem == \"my.rooftop.sherpa\" AND category == \"transcription\"",
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        Thread.detachNewThread { [self] in
            let stamp = DateFormatter()
            stamp.locale = Locale(identifier: "en_US_POSIX")
            stamp.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
            var pending = Data()
            let handle = output.fileHandleForReading
            while case let chunk = handle.availableData, !chunk.isEmpty {
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let message = object["eventMessage"] as? String
                    else { continue }
                    let at = (object["timestamp"] as? String).flatMap(stamp.date(from:)) ?? Date()
                    lock.withLock { messages.append(Line(text: message, at: at)) }
                }
            }
        }
    }

    var lines: [Line] { lock.withLock { messages } }

    func stop() { process.terminate() }
}

enum TapShape {
    static let firstChunk = 2752
    static let steadyChunk = 3200
    static let steadyChunkCount = 28
    static let converterTail = 440
}

struct Held {
    let transcription: Transcription
    let fed: Data
    let releasedAt: ContinuousClock.Instant
    let shownWhileHeld: [AssemblyAI.Transcript.Shown]
    let streamTerminated: Bool
    let outcome: Task<Outcome, Never>

    var hearing: [String] {
        shownWhileHeld.compactMap { if case .hearing(let text) = $0, !text.isEmpty { text } else { nil } }
    }
}

struct Outcome {
    let final: AssemblyAI.Final
    let settledAfter: Double
    let deliveredAfter: Double
}

final class Bench {
    let name: String
    let tail: LogTail
    let transcriber: Transcriber
    private let firstLine: Int
    private let server: Process?
    private let modeFile: URL?
    private let captureFile: URL?
    private let outputFile: URL?

    private init(name: String, tail: LogTail, transcriber: Transcriber, server: Process?, files: (mode: URL, capture: URL, output: URL)?) {
        self.name = name
        self.tail = tail
        self.transcriber = transcriber
        self.server = server
        firstLine = tail.lines.count
        modeFile = files?.mode
        captureFile = files?.capture
        outputFile = files?.output
    }

    static func fake(_ scenario: Scenario, binary: String, tail: LogTail, workspace: URL) async -> Bench? {
        let file = { (suffix: String) in workspace.appending(path: "\(scenario.name).\(suffix)") }
        let (ports, mode, capture, output) = (file("ports"), file("mode"), file("pcm"), file("out"))
        try? Data("\(scenario.mode)\n".utf8).write(to: mode)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = [ports.path, capture.path, scenario.mode, "--scenario-file", mode.path] + scenario.arguments
        server.standardOutput = try? FileHandle(forWritingTo: output)
        do { try server.run() } catch {
            TranscriptionCheck.expect(false, "\(scenario.name): the fake did not start: \(error.localizedDescription)")
            return nil
        }
        guard let endpoints = await endpoints(in: ports) else {
            server.terminate()
            TranscriptionCheck.expect(false, "\(scenario.name): the fake never wrote its ports to \(ports.path)")
            return nil
        }
        var limits = Dictation.Limits()
        if let idle = scenario.idle {
            limits.idle = idle
            limits.idleWithPanelOpen = idle
        }
        let transcriber = Transcriber(configuration: .init(key: scenario.key, endpoints: endpoints, limits: limits))
        return Bench(name: scenario.name, tail: tail, transcriber: transcriber, server: server, files: (mode, capture, output))
    }

    static func live(_ name: String, key: String, tail: LogTail) -> Bench {
        Bench(name: name, tail: tail, transcriber: Transcriber(configuration: .init(key: key, endpoints: .production)), server: nil, files: nil)
    }

    func setMode(_ mode: String) {
        guard let modeFile else { return }
        try? Data("\(mode)\n".utf8).write(to: modeFile)
    }

    var lines: [String] { tail.lines.dropFirst(firstLine).map(\.text) }

    func lines(_ prefix: String) -> [String] { lines.filter { $0.hasPrefix(prefix) } }

    func seconds(from start: String, to end: String) -> Double? {
        let window = tail.lines.dropFirst(firstLine)
        guard let from = window.first(where: { $0.text.hasPrefix(start) })?.at,
              let to = window.first(where: { $0.text.hasPrefix(end) })?.at
        else { return nil }
        return to.timeIntervalSince(from)
    }

    func waitFor(_ prefix: String, count: Int = 1, upTo seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if lines(prefix).count >= count { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lines(prefix).count >= count
    }

    var output: [String] {
        (outputFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").split(separator: "\n").map(String.init)
    }

    var capture: Data { captureFile.flatMap { try? Data(contentsOf: $0) } ?? Data() }

    @discardableResult
    func warm() async -> Bool {
        let before = lines("transcription opened ").count
        transcriber.warm()
        return await waitFor("transcription opened ", count: before + 1, upTo: 5)
    }

    func hold(_ pcm: Data, prefill: Double = 0, during: ((Int) -> Void)? = nil) async -> Held {
        var chunks = [pcm.prefix(TapShape.firstChunk)]
        var offset = TapShape.firstChunk
        while offset < pcm.count - TapShape.converterTail {
            chunks.append(pcm[offset..<min(offset + TapShape.steadyChunk, pcm.count - TapShape.converterTail)])
            offset += TapShape.steadyChunk
        }
        chunks.append(pcm.suffix(TapShape.converterTail))

        let (speech, continuation) = SpeechStream.makeStream(bufferingPolicy: .unbounded)
        var record = prefill > 0 ? nil : transcriber.press(speech)
        var shown: [AssemblyAI.Transcript.Shown] = []
        var terminated = false
        let began = ContinuousClock.now
        for (index, chunk) in chunks.enumerated() {
            try? await Task.sleep(until: began + .milliseconds(100 * index), clock: .continuous)
            if record == nil, began.duration(to: .now) >= .seconds(prefill) { record = transcriber.press(speech) }
            during?(index)
            if case .terminated = continuation.yield(Data(chunk)) { terminated = true }
            if let record { shown.append(record.shown) }
        }
        continuation.finish()
        let transcription = record ?? transcriber.press(speech)
        transcriber.release()
        let releasedAt = ContinuousClock.now
        marker.notice("check released bytes=\(pcm.count)")
        let outcome = Task {
            let settled = Task {
                while !Task.isCancelled {
                    if case .final = transcription.shown { return ContinuousClock.now }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return ContinuousClock.now
            }
            let final = await transcription.delivered
            let deliveredAt = ContinuousClock.now
            let settledAt = await settled.value
            return Outcome(
                final: final,
                settledAfter: releasedAt.duration(to: settledAt) / .seconds(1),
                deliveredAfter: releasedAt.duration(to: deliveredAt) / .seconds(1)
            )
        }
        return Held(transcription: transcription, fed: pcm, releasedAt: releasedAt, shownWhileHeld: shown, streamTerminated: terminated, outcome: outcome)
    }

    func outcome(_ held: Held) async -> Outcome {
        await held.outcome.value
    }

    // Dispatch time stops while the Mac sleeps and ContinuousClock does not, so closing the
    // lid mid-run is not read as a hang.
    func deadline(_ seconds: Double) -> DispatchWorkItem {
        let (name, tail, firstLine, outputFile) = (name, tail, firstLine, outputFile)
        let expired = DispatchWorkItem {
            print("  FAIL \(name): not done \(Int(seconds)) s after it started, the last lines were:")
            for line in tail.lines.dropFirst(firstLine).suffix(40) { print("  info \(line.text)") }
            let fake = outputFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            for line in fake.split(separator: "\n").suffix(20) { print("  info fake: \(line)") }
            tail.stop()
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: expired)
        return expired
    }

    func sync() async {
        _ = await TranscriptionCheck.markAndWaitForTail(tail, "check synced \(name) \(tail.lines.count)")
    }

    func close() async {
        await transcriber.close()
        await sync()
    }

    func stop() {
        server?.terminate()
    }

    private static func endpoints(in portFile: URL) async -> AssemblyAI.Endpoints? {
        for _ in 0..<100 {
            if let line = try? String(contentsOf: portFile, encoding: .utf8) {
                var fields: [String: URL] = [:]
                for pair in line.split(whereSeparator: \.isWhitespace) {
                    let parts = pair.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 { fields[String(parts[0])] = URL(string: String(parts[1])) }
                }
                if let token = fields["token"], let socket = fields["socket"] { return AssemblyAI.Endpoints(token: token, socket: socket) }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

struct Scenario {
    let name: String
    var mode = "ok"
    var arguments: [String] = []
    var key: String? = "fake"
    var idle: Duration?
    let run: (Bench) async -> Void
}

@main
enum TranscriptionCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let sentence = "S1 T0 frame 18. S1 T1 frame 30."
    static let secondHold = "S1 T2 frame 48. S1 T3 frame 60."
    static let merged = "S1 T0 frame 18. S1 T1 frame 36. S1 T2 frame 54. S1 T3 frame 60."

    static let scenarios = [
        Scenario(name: "warm", run: warm),
        Scenario(name: "merge", run: merge),
        Scenario(name: "new-utterance", run: newUtterance),
        Scenario(name: "gate", arguments: ["--answer-delay", "1.5"], run: gate),
        Scenario(name: "idle", idle: .seconds(2), run: idle),
        Scenario(name: "server-close", run: serverClose),
        Scenario(name: "drop-mid-hold", run: dropMidHold),
        Scenario(name: "ten", run: ten),
        Scenario(name: "backlog", arguments: ["--begin-delay", "2.5"], run: behind),
        Scenario(name: "catching-up", arguments: ["--begin-delay", "1.4"], run: behind),
        Scenario(name: "no-endpoint", mode: "no-endpoint", run: unanswered),
        Scenario(name: "late-endpoint", arguments: ["--answer-delay", "3.5"], run: unanswered),
        Scenario(name: "silent", mode: "silent", run: silent),
        Scenario(name: "paused", run: paused),
        Scenario(name: "close-1008", mode: "close-1008", run: refused),
        Scenario(name: "no-begin", mode: "no-begin", run: noBegin),
        Scenario(name: "token-401", mode: "token-401", run: refused),
        Scenario(name: "no-key", key: nil, run: refused),
        Scenario(name: "expired-once", mode: "expired-once", run: expiredOnce),
        Scenario(name: "no-termination", mode: "no-termination", run: noTermination),
    ]

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            print("usage: transcription-check <fake-assemblyai binary> [scenario ...] | --live [--prefill seconds] | --live-ten")
            exit(2)
        }
        let tail = LogTail()
        guard await markAndWaitForTail(tail, "check tail ready") != nil else {
            print("  FAIL log stream never showed this process's own marker line")
            tail.stop()
            exit(1)
        }
        let workspace = FileManager.default.temporaryDirectory.appending(path: "transcription-check-\(getpid())")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        switch mode {
        case "--live":
            let prefill = zip(arguments, arguments.dropFirst()).first { $0.0 == "--prefill" }.flatMap { Double($0.1) } ?? 0
            await checkLive(tail: tail, workspace: workspace, prefill: prefill)
        case "--live-ten":
            await checkLiveTen(tail: tail, workspace: workspace)
        default:
            arguments.removeFirst()
            for scenario in scenarios where arguments.isEmpty || arguments.contains(scenario.name) {
                print(scenario.name)
                guard let bench = await Bench.fake(scenario, binary: mode, tail: tail, workspace: workspace) else { continue }
                let deadline = bench.deadline(60)
                await scenario.run(bench)
                await bench.close()
                deadline.cancel()
                assessSession(bench)
                bench.stop()
            }
        }
        tail.stop()
        try? FileManager.default.removeItem(at: workspace)
        exit(failures == 0 ? 0 : 1)
    }

    static func assessSession(_ bench: Bench) {
        for line in bench.lines where line.hasPrefix("transcription ") { print("  info \(line)") }
        let unprocessed = bench.output.compactMap { line in
            line.contains(" force-endpoint ") ? line.components(separatedBy: "unprocessed=").last.flatMap(Double.init) : nil
        }
        expect(unprocessed.allSatisfy { $0 <= 0.6 }, "\(bench.name): every ForceEndpoint went with at most 0.6 s unprocessed, got \(unprocessed)")
        let delivered = bench.lines("transcription delivered ").compactMap { fields(of: $0)["utterance"] }
        expect(Set(delivered).count == delivered.count, "\(bench.name): no utterance was delivered twice, got \(delivered)")
        expect(!bench.lines.contains { $0.contains("code=3007") }, "\(bench.name): no 3007 input violation")
    }

    static func warm(_ bench: Bench) async {
        expect(await bench.warm(), "warm: the session opened before the press")
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .heard(sentence), "warm: delivered '\(sentence)', got \(outcome.final)")
        expect(abs(outcome.settledAfter - outcome.deliveredAfter) <= 0.05, "warm: the final showed with the delivery, \(format(outcome.settledAfter)) and \(format(outcome.deliveredAfter)) s after the release")
        expect((1.2...1.5).contains(outcome.deliveredAfter), "warm: delivered \(format(outcome.deliveredAfter)) s after the release, expected 1.2 to 1.5")
        expectOwnWords(bench, held, "S1 T")
        await bench.sync()
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=endpoint"], "warm: one final via endpoint")
        expect(plans(bench) == ["endpoint"], "warm: finishing plan endpoint, got \(plans(bench))")
        expect(bench.lines("transcription delivered ").map(head) == ["transcription delivered session=1 utterance=1 holds=1"], "warm: one delivery of one hold")
        expect(bench.lines("transcription ended").isEmpty, "warm: the session stays open after the delivery")
        await bench.close()
        expect(bench.lines("transcription connecting ") == ["transcription connecting session=1 cause=panel"], "warm: the only connect came from the panel")
        expect(bench.lines("transcription opened ").map(head) == ["transcription opened session=1 token=minted"], "warm: one session opened")
        expectEnded(bench, session: 1, utterances: 1)
        expectCapture(bench, [held.fed])
    }

    static func merge(_ bench: Bench) async {
        await bench.warm()
        let first = await bench.hold(tone(0))
        try? await Task.sleep(for: .milliseconds(500))
        let second = await bench.hold(tone(1))
        expect(first.transcription === second.transcription, "merge: a press 0.5 s after the release returns the same record")
        let outcome = await bench.outcome(second)
        expect(outcome.final == .heard(merged), "merge: hold 2 continued hold 1's open turn, '\(merged)', got \(outcome.final)")
        expect((1.2...1.5).contains(outcome.deliveredAfter), "merge: delivered \(format(outcome.deliveredAfter)) s after the second release, expected 1.2 to 1.5")
        expect(!second.hearing.isEmpty && second.hearing.allSatisfy { $0.hasPrefix("S1 T0 frame 18. S1 T1 frame ") }, "merge: every sample during hold 2 starts with hold 1's words, got \(Set(second.hearing.map { $0.prefix(40) }))")
        await bench.sync()
        expect(bench.output.filter { $0.contains(" force-endpoint ") }.count == 1, "merge: one ForceEndpoint, after the second hold, got \(bench.output.filter { $0.contains(" force-endpoint ") })")
        expect(bench.lines("transcription delivered ").map(head) == ["transcription delivered session=1 utterance=1 holds=2"], "merge: one delivery of two holds, got \(bench.lines("transcription delivered "))")
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=endpoint"], "merge: one final via endpoint")
        await bench.close()
        expect(bench.lines("transcription opened ").count == 1, "merge: one session opened")
        expectEnded(bench, session: 1, utterances: 1)
        expectCapture(bench, [first.fed, second.fed])
    }

    static func newUtterance(_ bench: Bench) async {
        await bench.warm()
        let first = await bench.hold(tone(0))
        try? await Task.sleep(for: .milliseconds(1500))
        let second = await bench.hold(tone(1))
        expect(first.transcription !== second.transcription, "new utterance: a press 1.5 s after the release returns a new record")
        let one = await bench.outcome(first)
        let two = await bench.outcome(second)
        expect(one.final == .heard(sentence) && two.final == .heard(secondHold), "new utterance: delivered '\(sentence)' then '\(secondHold)', got \(one.final) and \(two.final)")
        expect(second.shownWhileHeld.first == .hearing(""), "new utterance: the second record starts empty")
        expect(second.hearing.allSatisfy { !$0.contains("T0 ") && !$0.contains("T1 ") }, "new utterance: no sample during hold 2 shows hold 1's turns, got \(Set(second.hearing.map { $0.prefix(20) }))")
        await bench.sync()
        expect(
            bench.lines("transcription delivered ").map(head) == ["transcription delivered session=1 utterance=1 holds=1", "transcription delivered session=1 utterance=2 holds=1"],
            "new utterance: two deliveries on session 1"
        )
        await bench.close()
        expect(bench.lines("transcription opened ").count == 1, "new utterance: one session opened")
        expectEnded(bench, session: 1, utterances: 2)
        expectCapture(bench, [first.fed, second.fed])
    }

    static func gate(_ bench: Bench) async {
        await bench.warm()
        let first = await bench.hold(tone(0))
        try? await Task.sleep(for: .milliseconds(1200))
        let second = await bench.hold(tone(1))
        let one = await bench.outcome(first)
        let two = await bench.outcome(second)
        expect(one.final == .heard(sentence) && two.final == .heard(secondHold), "gate: delivered '\(sentence)' then '\(secondHold)', got \(one.final) and \(two.final)")
        expect((2.4...3.0).contains(one.deliveredAfter), "gate: utterance 1 delivered as its 1.5 s answer landed after the 1 s window, \(format(one.deliveredAfter)) s after the release")
        await bench.sync()
        let lines = bench.lines
        let delivered = lines.firstIndex { $0.hasPrefix("transcription delivered session=1 utterance=1 ") } ?? lines.count
        let heard = lines.firstIndex { $0.hasPrefix("heard session=1 utterance=2 ") } ?? -1
        expect(delivered < heard, "gate: utterance 1 was delivered before any turn of utterance 2, at lines \(delivered) and \(heard)")
        expect(second.hearing.allSatisfy { !$0.contains("T0 ") && !$0.contains("T1 ") }, "gate: utterance 2 never showed utterance 1's turns")
        await bench.close()
        expectEnded(bench, session: 1, utterances: 2)
        expectCapture(bench, [first.fed, second.fed])
    }

    static func idle(_ bench: Bench) async {
        await bench.warm()
        let first = await bench.hold(tone(0))
        _ = await bench.outcome(first)
        marker.notice("check cool")
        bench.transcriber.cool()
        let closed = await bench.waitFor("transcription closing session=1 reason=idle", upTo: 4)
        let after = bench.seconds(from: "check cool", to: "transcription closing session=1 reason=idle")
        expect(closed && after.map { (2.0...2.5).contains($0) } == true, "idle: the session closed \(after.map(format) ?? "never") s after the panel closed, expected 2.0 to 2.5")
        expect(await bench.waitFor("transcription ended session=1 ", upTo: 3), "idle: the closed session read to its Termination")
        let second = await bench.hold(tone(1))
        let two = await bench.outcome(second)
        expect(two.final == .heard("S2 T0 frame 18. S2 T1 frame 30."), "idle: the next press delivered on session 2, got \(two.final)")
        await bench.close()
        expect(
            bench.lines("transcription connecting ") == ["transcription connecting session=1 cause=panel", "transcription connecting session=2 cause=press"],
            "idle: the panel warmed session 1 and the next press connected session 2, got \(bench.lines("transcription connecting "))"
        )
        expect(
            bench.lines("transcription opened ").map(head) == ["transcription opened session=1 token=minted", "transcription opened session=2 token=reused"],
            "idle: session 2 reused the token, got \(bench.lines("transcription opened "))"
        )
        expectEnded(bench, session: 1, utterances: 1)
        expectEnded(bench, session: 2, utterances: 1)
        expectCapture(bench, [first.fed, second.fed])
    }

    static let dropped = "transcription failed session=1 stage=open reason=serverError code=1011 detail=Internal error"

    static func serverClose(_ bench: Bench) async {
        await bench.warm()
        bench.setMode("drop")
        let failed = await bench.waitFor("transcription failed ", upTo: 3)
        bench.setMode("ok")
        expect(failed && bench.lines("transcription failed ") == [dropped], "server close: \(dropped), got \(bench.lines("transcription failed "))")
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .heard("S2 T0 frame 18. S2 T1 frame 30."), "server close: the next press delivered only session 2's words, got \(outcome.final)")
        await bench.close()
        expect(
            bench.lines("transcription connecting ") == ["transcription connecting session=1 cause=panel", "transcription connecting session=2 cause=press"],
            "server close: nothing reconnected until the press, got \(bench.lines("transcription connecting "))"
        )
        expectEnded(bench, session: 2, utterances: 1)
    }

    static func dropMidHold(_ bench: Bench) async {
        await bench.warm()
        let held = await bench.hold(tone(0)) { index in if index == 15 { bench.setMode("drop") } }
        bench.setMode("ok")
        let outcome = await bench.outcome(held)
        let failure = AssemblyAI.Final.failed(.serverError(code: 1011, reason: "Internal error"))
        expect(outcome.final == failure, "drop mid-hold: the utterance delivered \(failure), got \(outcome.final)")
        expect(held.streamTerminated, "drop mid-hold: once the session dropped, the stream refused the rest of the feed")
        await bench.sync()
        expect(bench.lines("transcription failed ") == [dropped], "drop mid-hold: \(dropped)")
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=failure"], "drop mid-hold: one final via failure")
        let next = await bench.hold(tone(1))
        let recovered = await bench.outcome(next)
        expect(recovered.final == .heard("S2 T0 frame 18. S2 T1 frame 30."), "drop mid-hold: the next hold delivered on session 2, got \(recovered.final)")
        await bench.close()
        expectEnded(bench, session: 2, utterances: 1)
    }

    static func ten(_ bench: Bench) async {
        await bench.warm()
        var held: [Held] = []
        for index in 0..<10 {
            if index > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
            held.append(await bench.hold(tone(index, seconds: 1)))
        }
        var finals: [AssemblyAI.Final] = []
        for hold in held { finals.append(await bench.outcome(hold).final) }
        let mismatched = finals.enumerated().filter { index, final in
            guard case .heard(let text) = final else { return true }
            return text.range(of: #"^S1 T\#(index) frame \d+\.$"#, options: .regularExpression) == nil
        }
        expect(mismatched.isEmpty, "ten: utterance k delivered only its own turn S1 T<k-1>, got \(finals)")
        expect(Set(held.map { ObjectIdentifier($0.transcription) }).count == 10, "ten: ten records")
        await bench.sync()
        let delivered = bench.lines("transcription delivered ").map(head)
        expect(delivered == (1...10).map { "transcription delivered session=1 utterance=\($0) holds=1" }, "ten: utterances 1 to 10 delivered once each on session 1, got \(delivered)")
        await bench.close()
        expect(bench.lines("transcription opened ").count == 1, "ten: one session opened for ten utterances")
        expect(bench.output.filter { $0.hasPrefix("mint ") }.count == 1, "ten: the fake minted one token")
        expectEnded(bench, session: 1, utterances: 10)
        expectCapture(bench, held.map(\.fed))
    }

    static func behind(_ bench: Bench) async {
        let first = await bench.hold(tone(0))
        let one = await bench.outcome(first)
        expect(one.final == .heard(sentence), "\(bench.name): the backlogged hold delivered every turn '\(sentence)', got \(one.final)")
        await bench.sync()
        let finishing = bench.lines("transcription finishing ").first ?? ""
        if bench.name == "backlog" {
            expect(finishing.contains(" plan=wait ") && (fields(of: finishing)["wait"] ?? 0) > 0, "backlog: the first hold waited past the merge window for the server, got \(finishing)")
        } else {
            expect(finishing.contains(" plan=endpoint "), "\(bench.name): the server caught up inside the merge window, got \(finishing)")
        }
        try? await Task.sleep(for: .milliseconds(500))
        let second = await bench.hold(tone(1))
        let two = await bench.outcome(second)
        expect(two.final == .heard(secondHold), "\(bench.name): a second hold on the same socket still got words, got \(two.final)")
        expect(bench.lines("transcription final ").allSatisfy { $0.contains(" via=endpoint ") }, "\(bench.name): every final came via endpoint")
        await bench.close()
        expect(bench.lines("transcription connecting ") == ["transcription connecting session=1 cause=press"], "\(bench.name): the press connected the only session")
        expectEnded(bench, session: 1, utterances: 2)
        expectCapture(bench, [first.fed, second.fed])
    }

    static func unanswered(_ bench: Bench) async {
        await bench.warm()
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        let partial = AssemblyAI.Final.heard("S1 T0 frame 18. S1 T1 frame 30")
        expect(outcome.final == partial, "\(bench.name): the fallback delivered the words so far, got \(outcome.final)")
        expect((3.7...4.3).contains(outcome.deliveredAfter), "\(bench.name): delivered \(format(outcome.deliveredAfter)) s after the release, expected 3.7 to 4.3")
        await bench.sync()
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=fallback"], "\(bench.name): one final via fallback")
        expect(bench.lines("transcription closing session=1 ") == ["transcription closing session=1 reason=retire"], "\(bench.name): the unanswered socket retired")
        let late = await bench.waitFor("transcription late session=1 turn=1 formatted=true end=true text=S1 T1 frame 30.", upTo: 3)
        let lines = bench.lines
        let deliveredAt = lines.firstIndex { $0.hasPrefix("transcription delivered ") } ?? lines.count
        let lateAt = lines.firstIndex { $0.hasPrefix("transcription late session=1 turn=1 ") } ?? -1
        expect(late && deliveredAt < lateAt, "\(bench.name): the server's answer 'S1 T1 frame 30.' arrived after the delivery")
        expect(held.transcription.shown == .final(partial), "\(bench.name): and changed nothing")
        expect(await bench.waitFor("transcription ended session=1 ", upTo: 6), "\(bench.name): the retired socket read to its Termination")
        await bench.close()
        expect(bench.lines("transcription connecting session=2 ") == ["transcription connecting session=2 cause=panel"], "\(bench.name): the open panel warmed a new session")
    }

    static func silent(_ bench: Bench) async {
        await bench.warm()
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .silence, "silent: delivered silence, got \(outcome.final)")
        expect((1.2...1.5).contains(outcome.deliveredAfter), "silent: delivered \(format(outcome.deliveredAfter)) s after the release")
        await bench.sync()
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=endpoint"], "silent: the empty answer settled it via endpoint")
        await bench.close()
        expectEnded(bench, session: 1, utterances: 1)
        expectCapture(bench, [held.fed])
    }

    static func paused(_ bench: Bench) async {
        await bench.warm()
        let held = await bench.hold(tone(0) + Data(count: 32_000))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .heard(sentence), "paused: 1 s of trailing silence still delivered '\(sentence)', got \(outcome.final)")
        await bench.sync()
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=endpoint"], "paused: via endpoint")
        await bench.close()
        expectEnded(bench, session: 1, utterances: 1)
        expectCapture(bench, [held.fed])
    }

    static func refused(_ bench: Bench) async {
        let (failure, detail): (AssemblyAI.Failure, String) = switch bench.name {
        case "close-1008":
            (.serverError(code: 1008, reason: "Unauthorized Connection: Invalid API key"), "stage=connecting reason=serverError code=1008 detail=Unauthorized Connection: Invalid API key")
        case "token-401":
            (.tokenRefused(status: 401, detail: #"{"error":"Invalid API key"}"#), #"stage=minting reason=tokenRefused status=401 detail={"error":"Invalid API key"}"#)
        default:
            (.noAPIKey, "stage=minting reason=noAPIKey")
        }
        bench.transcriber.warm()
        _ = await bench.waitFor("transcription failed session=1 ", upTo: 5)
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .failed(failure), "\(bench.name): delivered \(failure), got \(outcome.final)")
        await bench.sync()
        let failed = bench.lines("transcription failed ").map(failureDetail)
        expect(failed == [detail, detail], "\(bench.name): the warm connect and the press's connect each failed once with \(detail), got \(failed)")
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=2 utterance=1 via=failure"], "\(bench.name): one final via failure")
        expect(bench.lines("transcription ended").isEmpty, "\(bench.name): no session ended")
    }

    static func noBegin(_ bench: Bench) async {
        bench.transcriber.warm()
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .failed(.timedOut), "no-begin: delivered timedOut, got \(outcome.final)")
        await bench.sync()
        expect(bench.lines("transcription failed ").map(failureDetail) == ["stage=connecting reason=timedOut"], "no-begin: one failure, the warm connect's 5 s timeout")
        expect(bench.lines("transcription final ").map(head) == ["transcription final session=1 utterance=1 via=failure"], "no-begin: the hold waiting on it failed")
    }

    static func expiredOnce(_ bench: Bench) async {
        await bench.warm()
        let first = await bench.hold(tone(0))
        let one = await bench.outcome(first)
        await bench.transcriber.close()
        await bench.warm()
        let second = await bench.hold(tone(1))
        let two = await bench.outcome(second)
        expect(one.final == .heard(sentence) && two.final == .heard("S3 T0 frame 18. S3 T1 frame 30."), "expired-once: delivered on sessions 1 and 3 of the fake, got \(one.final) and \(two.final)")
        await bench.close()
        expect(bench.lines("transcription retry ") == ["transcription retry session=2 reason=expiredToken"], "expired-once: session 2 retried once on the expired token")
        expect(
            bench.lines("transcription opened ").map(head) == ["transcription opened session=1 token=minted", "transcription opened session=2 token=minted"],
            "expired-once: session 2 opened with a fresh token, got \(bench.lines("transcription opened "))"
        )
        expect(bench.output.filter { $0.hasPrefix("mint ") }.count == 2, "expired-once: the fake minted 2 tokens")
        expectEnded(bench, session: 1, utterances: 1)
        expectEnded(bench, session: 2, utterances: 1)
    }

    static func noTermination(_ bench: Bench) async {
        await bench.warm()
        let held = await bench.hold(tone(0))
        let outcome = await bench.outcome(held)
        expect(outcome.final == .heard(sentence), "no-termination: delivered '\(sentence)' via endpoint, got \(outcome.final)")
        let closing = ContinuousClock.now
        await bench.close()
        let waited = closing.duration(to: .now) / .seconds(1)
        expect((4.9...5.6).contains(waited), "no-termination: close() gave up after the 5 s drain, took \(format(waited)) s")
        expect(bench.lines("transcription failed ").map(failureDetail) == ["stage=closing reason=timedOut"], "no-termination: one failure, stage=closing reason=timedOut")
        expect(bench.lines("transcription ended").isEmpty, "no-termination: no 'ended' line")
        expect(!bench.lines("transcription final ").contains { $0.contains("via=termination") }, "no-termination: nothing came via termination")
    }

    static func checkLive(tail: LogTail, workspace: URL, prefill: Double) async {
        print("live\(prefill > 0 ? " with \(prefill) s prefilled" : "")")
        guard let key = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"], !key.isEmpty else {
            expect(false, "live: ASSEMBLYAI_API_KEY is not set")
            return
        }
        guard let first = said("Open the settings page.", into: workspace.appending(path: "first.wav")),
              let second = said("Then click the blue button at the top.", into: workspace.appending(path: "second.wav"))
        else {
            expect(false, "live: say did not write 16 kHz PCM16 WAVs to \(workspace.path)")
            return
        }
        let bench = Bench.live("live", key: key, tail: tail)
        let deadline = bench.deadline(60)
        expect(await bench.warm(), "live: the panel warmed a session")
        let spoken = await bench.hold(first + Data(count: 48_000) + second, prefill: prefill)
        let outcome = await bench.outcome(spoken)
        let plan = prefill > 0 ? "wait" : "endpoint"
        expect(bench.lines("transcription finishing ").first?.contains(" plan=\(plan) ") == true, "live: the hold finished by \(plan)")
        expect(bench.lines("transcription final ").allSatisfy { $0.contains(" via=endpoint ") }, "live: the final came via endpoint")
        if prefill == 0 {
            expect((1.2...1.7).contains(outcome.deliveredAfter), "live: delivered \(format(outcome.deliveredAfter)) s after the release, expected 1.2 to 1.7")
            expect(spoken.hearing.contains { $0.hasPrefix("Open the") }, "live: 'Open the' showed while held")
        }
        if case .heard(let sentence) = outcome.final {
            expect(letters(sentence) == "openthesettingspagethenclickthebluebuttonatthetop", "live: the delivery is both sentences, got '\(sentence)'")
            expect(sentence.first?.isUppercase == true && sentence.hasSuffix(".") && sentence.contains(". "), "live: punctuated as two sentences, got '\(sentence)'")
        } else {
            expect(false, "live: the delivery is both sentences, got \(outcome.final)")
        }
        try? await Task.sleep(for: .milliseconds(1500))
        let quiet = await bench.outcome(await bench.hold(Data(count: 64_000)))
        expect(quiet.final == .silence, "live: 2 s of silence delivers silence, got \(quiet.final)")
        await bench.close()
        deadline.cancel()
        for line in bench.lines where line.hasPrefix("transcription ") || line.hasPrefix("heard ") { print("  info \(line)") }
        expect(bench.lines("transcription opened ").count == 1, "live: one session served both utterances")
        expect(!bench.lines.contains { $0.contains("code=3007") }, "live: no 3007 input or rate violation")
        expectEnded(bench, session: 1, utterances: 2, tolerance: liveTolerance)
    }

    static func checkLiveTen(tail: LogTail, workspace: URL) async {
        print("live ten")
        guard let key = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"], !key.isEmpty else {
            expect(false, "live ten: ASSEMBLYAI_API_KEY is not set")
            return
        }
        let sentences = [
            "Open the settings page.", "Then click the blue button.", "Close the window now.", "Search for the weather.",
            "Turn on the dark mode.", "Read the first message.", "Move the file to the trash.", "Play some quiet music.",
            "Call my brother tonight.", "Show me the calendar.", "Send the report", "to Sam.",
        ]
        var audio: [Data] = []
        for (index, sentence) in sentences.enumerated() {
            guard let pcm = said(sentence, into: workspace.appending(path: "ten-\(index).wav")) else {
                expect(false, "live ten: say did not write a 16 kHz PCM16 WAV for '\(sentence)'")
                return
            }
            audio.append(pcm)
        }
        let bench = Bench.live("live ten", key: key, tail: tail)
        let deadline = bench.deadline(180)
        expect(await bench.warm(), "live ten: the panel warmed a session")
        var utterances: [(held: Held, expected: String)] = []
        for index in 0..<10 {
            if index > 0 { try? await Task.sleep(for: .milliseconds(1500)) }
            utterances.append((await bench.hold(audio[index]), sentences[index]))
        }
        try? await Task.sleep(for: .milliseconds(1500))
        let pairFirst = await bench.hold(audio[10])
        try? await Task.sleep(for: .milliseconds(500))
        let pairSecond = await bench.hold(audio[11])
        expect(pairFirst.transcription === pairSecond.transcription, "live ten: holds 0.5 s apart joined one utterance")
        utterances.append((pairSecond, sentences[10] + " " + sentences[11]))
        for (held, expected) in utterances {
            let outcome = await bench.outcome(held)
            let got = if case .heard(let text) = outcome.final { text } else { "\(outcome.final)" }
            expect(letters(got) == letters(expected), "live ten: utterance \(held.transcription.number) is '\(expected)', got '\(got)'")
            expect((1.2...1.7).contains(outcome.deliveredAfter), "live ten: utterance \(held.transcription.number) delivered \(format(outcome.deliveredAfter)) s after its release, expected 1.2 to 1.7")
        }
        let split = await bench.outcome(pairSecond)
        if case .heard(let text) = split.final {
            expect(!text.dropLast().contains { ".?!".contains($0) }, "live ten: a sentence split across two holds reads as one sentence, got '\(text)'")
        }
        await bench.close()
        deadline.cancel()
        for line in bench.lines where line.hasPrefix("transcription ") { print("  info \(line)") }
        let opened = bench.lines("transcription opened ").count
        expect((1...2).contains(opened), "live ten: \(opened) session(s) opened for 11 utterances, expected 1 and at most 2")
        expect(bench.lines("transcription delivered ").count == 11, "live ten: 11 deliveries")
        expect(!bench.lines.contains { $0.contains("code=1008") || $0.contains("code=3007") }, "live ten: no 1008 refusal and no 3007 violation")
        expectEnded(bench, session: opened, utterances: nil, tolerance: liveTolerance)
    }

    // A turn's unformatted end, lowercase, shows until its formatted end lands.
    static func expectOwnWords(_ bench: Bench, _ held: Held, _ prefix: String) {
        expect(!held.hearing.isEmpty && held.hearing.allSatisfy { $0.uppercased().hasPrefix(prefix) }, "\(bench.name): words showed while held and every sample was this session's, \(prefix)..., got \(Set(held.hearing.map { $0.prefix(6) }))")
    }

    // The real server rounds to whole seconds: 17.814 s sent came back as 18, 7.152 s as 7.
    static let liveTolerance = 0.5

    static func expectEnded(_ bench: Bench, session: Int, utterances: Int?, tolerance: Double = 0) {
        let ended = bench.lines("transcription ended session=\(session) ")
        let numbers = ended.first.map { fields(of: $0) } ?? [:]
        let sent = numbers["sent"] ?? -1
        let server = numbers["server"] ?? -2
        expect(
            ended.count == 1 && abs(sent - server) <= tolerance && utterances.map { numbers["utterances"] == Double($0) } != false,
            "\(bench.name): session \(session) ended once\(utterances.map { " after \($0) utterance(s)" } ?? ""), sent \(sent) s and the server counted \(server) s, got \(ended)"
        )
    }

    static func expectCapture(_ bench: Bench, _ feeds: [Data]) {
        let capture = bench.capture
        var offset = 0
        var padding: [Int] = []
        var matches = true
        for feed in feeds {
            guard capture.count - offset >= feed.count, capture[offset..<offset + feed.count] == feed else {
                matches = false
                break
            }
            offset += feed.count
            var zeros = 0
            while offset < capture.count, capture[offset] == 0, zeros < 1600 {
                offset += 1
                zeros += 1
            }
            padding.append(zeros)
        }
        expect(matches && offset == capture.count, "\(bench.name): the fake received the \(feeds.count) feed(s) in order, padded with \(padding) zero bytes, \(capture.count) bytes in all")
    }

    static func plans(_ bench: Bench) -> [String] {
        bench.lines("transcription finishing ").map { line in
            line.split(separator: " ").first { $0.hasPrefix("plan=") }.map { String($0.dropFirst(5)) } ?? line
        }
    }

    static func head(_ line: String) -> String {
        line.split(separator: " ").prefix { !$0.hasPrefix("after=") && !$0.hasPrefix("text=") }.joined(separator: " ")
    }

    static func failureDetail(_ line: String) -> String {
        line.range(of: "stage=").map { String(line[$0.lowerBound...]) } ?? line
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }

    static func format(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    static func said(_ text: String, into wav: URL) -> Data? {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", text]
        try? say.run()
        say.waitUntilExit()
        return (try? Data(contentsOf: wav)).flatMap { pcm(inWAV: $0) }
    }

    static func fields(of line: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for pair in line.split(separator: " ") {
            let parts = pair.split(separator: "=")
            if parts.count == 2, let number = Double(parts[1]) { result[String(parts[0])] = number }
        }
        return result
    }

    static func markAndWaitForTail(_ tail: LogTail, _ text: String) async -> Int? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            marker.notice("\(text, privacy: .public)")
            try? await Task.sleep(for: .milliseconds(250))
            if let index = tail.lines.lastIndex(where: { $0.text == text }) { return index }
        }
        return nil
    }

    static func tone(_ variant: Int, seconds: Double? = nil) -> Data {
        let full = TapShape.firstChunk + TapShape.steadyChunk * TapShape.steadyChunkCount + TapShape.converterTail
        let count = seconds.map { Int($0 * 32_000) } ?? full
        let pitch = 440 + 20 * Double(variant)
        let samples = (0..<count / 2).map { index in
            Int16(8000 * sin(2 * Double.pi * pitch * Double(index) / 16_000)) | 1
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    static func pcm(inWAV file: Data) -> Data? {
        func number(at offset: Int, size: Int) -> Int {
            file[offset..<offset + size].reversed().reduce(0) { $0 << 8 | Int($1) }
        }
        var offset = 12
        var isSpeechFormat = false
        while offset + 8 <= file.count {
            let id = String(decoding: file[offset..<offset + 4], as: UTF8.self)
            let size = number(at: offset + 4, size: 4)
            if id == "fmt " {
                isSpeechFormat = number(at: offset + 10, size: 2) == 1 && number(at: offset + 12, size: 4) == 16_000
                    && number(at: offset + 22, size: 2) == 16
            }
            if id == "data" { return isSpeechFormat ? file.subdata(in: offset + 8..<min(offset + 8 + size, file.count)) : nil }
            offset += 8 + size + size % 2
        }
        return nil
    }
}
