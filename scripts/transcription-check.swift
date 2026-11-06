import Foundation
import os

private let marker = Logger(subsystem: "my.rooftop.sherpa", category: "transcription")

nonisolated final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
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
                    lock.withLock { messages.append(message) }
                }
            }
        }
    }

    var lines: [String] { lock.withLock { messages } }

    func stop() { process.terminate() }
}

struct Scenario {
    let name: String
    var fake: String? = nil
    var fakeArguments: [String] = []
    let finals: [AssemblyAI.Final]
    let via: String
    var plan: String? = nil
    var deliveredWithin: ClosedRange<Double>? = nil
    var failure: String? = nil
    var lateTurn: String? = nil
    var overlapping = false
    var trailingSilence = 0.0
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
    let fedAt: ContinuousClock.Instant
    let firstLine: Int
    let shownWhileFeeding: [AssemblyAI.Transcript.Shown]
    let streamTerminated: Bool
    let outcome: Task<(final: AssemblyAI.Final, deliveredAt: ContinuousClock.Instant, closedAt: ContinuousClock.Instant), Never>
}

struct Run {
    let held: Held
    let final: AssemblyAI.Final
    let deliveredAfter: Double
    let closedAfter: Double
    let shownAfterDrain: AssemblyAI.Transcript.Shown
    let window: [String]
    var captured = Data()

    var lines: [String] { window.filter { $0.contains("session=\(held.transcription.number) ") } }
}

@main
enum TranscriptionCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let heard = AssemblyAI.Final.heard("S1 frame 15. S1 frame 30.")
    static let partial = AssemblyAI.Final.heard("S1 frame 15. S1 frame 30")
    static let scenarios = [
        Scenario(name: "ok", finals: [heard], via: "endpoint", plan: "endpoint", deliveredWithin: 0.1...1.0),
        Scenario(name: "silent", finals: [.silence], via: "termination", plan: "terminate", deliveredWithin: 0...1.0),
        Scenario(name: "backlog", fake: "ok", fakeArguments: ["--begin-delay", "2.5"], finals: [heard], via: "termination", plan: "terminate", deliveredWithin: 0...1.0),
        Scenario(name: "catching-up", fake: "ok", fakeArguments: ["--begin-delay", "1.4"], finals: [heard], via: "termination", plan: "terminate", deliveredWithin: 0...1.0),
        Scenario(name: "paused", fake: "ok", finals: [heard], via: "endpoint", plan: "endpoint", deliveredWithin: 0.1...1.0, trailingSilence: 1.0),
        Scenario(name: "backlog-no-termination", fake: "no-termination", fakeArguments: ["--begin-delay", "2.5"], finals: [heard], via: "fallback", plan: "terminate", deliveredWithin: 4.9...5.5, failure: "stage=closing reason=timedOut"),
        Scenario(name: "no-endpoint", finals: [partial], via: "fallback", plan: "endpoint", deliveredWithin: 2.7...3.3, lateTurn: "S1 frame 30."),
        Scenario(name: "late-endpoint", fake: "ok", fakeArguments: ["--answer-delay", "3.5"], finals: [partial], via: "fallback", plan: "endpoint", deliveredWithin: 2.7...3.3, lateTurn: "S1 frame 30."),
        Scenario(name: "no-termination", finals: [heard], via: "endpoint", plan: "endpoint", deliveredWithin: 0.1...1.0, failure: "stage=closing reason=timedOut"),
        Scenario(name: "close-1008", finals: [.failed(.serverError(code: 1008, reason: "Unauthorized Connection: Invalid API key"))], via: "failure", failure: "stage=connecting reason=serverError code=1008 detail=Unauthorized Connection: Invalid API key"),
        Scenario(name: "no-begin", finals: [.failed(.timedOut)], via: "failure", failure: "stage=connecting reason=timedOut"),
        Scenario(name: "token-401", finals: [.failed(.tokenRefused(status: 401, detail: #"{"error":"Invalid API key"}"#))], via: "failure", failure: #"stage=minting reason=tokenRefused status=401 detail={"error":"Invalid API key"}"#),
        Scenario(name: "no-key", fake: "ok", finals: [.failed(.noAPIKey)], via: "failure", failure: "stage=minting reason=noAPIKey"),
        Scenario(name: "reuse", fake: "ok", finals: [heard, .heard("S2 frame 15. S2 frame 30.")], via: "endpoint", plan: "endpoint", deliveredWithin: 0.1...1.0),
        Scenario(name: "expired-once", finals: [heard, .heard("S3 frame 15. S3 frame 30.")], via: "endpoint", plan: "endpoint", deliveredWithin: 0.1...1.0),
        Scenario(name: "overlap", fake: "ok", fakeArguments: ["--answer-delay", "1.5"], finals: [heard, .heard("S2 frame 15. S2 frame 30.")], via: "endpoint", plan: "endpoint", deliveredWithin: 1.4...2.2, overlapping: true),
    ]

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let live = arguments.first == "--live"
        let tail = LogTail()
        let ready = await markAndWaitForTail(tail, "check tail ready")
        guard ready != nil else {
            print("  FAIL log stream never showed this process's own marker line")
            exit(1)
        }
        let workspace = FileManager.default.temporaryDirectory.appending(path: "transcription-check-\(getpid())")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        if live {
            let prefill = zip(arguments, arguments.dropFirst()).first { $0.0 == "--prefill" }.flatMap { Double($0.1) } ?? 0
            await checkLive(tail: tail, workspace: workspace, prefill: prefill)
        } else if let fake = arguments.first {
            arguments.removeFirst()
            for scenario in scenarios where arguments.isEmpty || arguments.contains(scenario.name) {
                await check(scenario, fake: fake, tail: tail, workspace: workspace)
            }
        } else {
            print("usage: transcription-check <fake-assemblyai binary> [scenario ...] | --live [--prefill seconds]")
            exit(2)
        }
        tail.stop()
        try? FileManager.default.removeItem(at: workspace)
        exit(failures == 0 ? 0 : 1)
    }

    static func check(_ scenario: Scenario, fake: String, tail: LogTail, workspace: URL) async {
        print("\(scenario.name)")
        let portFile = workspace.appending(path: "\(scenario.name).ports")
        let captureFile = workspace.appending(path: "\(scenario.name).pcm")
        let stdoutFile = workspace.appending(path: "\(scenario.name).out")
        FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: fake)
        server.arguments = [portFile.path, captureFile.path, scenario.fake ?? scenario.name] + scenario.fakeArguments
        server.standardOutput = try? FileHandle(forWritingTo: stdoutFile)
        do { try server.run() } catch {
            expect(false, "\(scenario.name): the fake did not start: \(error.localizedDescription)")
            return
        }
        defer { server.terminate() }
        guard let endpoints = await endpoints(in: portFile) else {
            expect(false, "\(scenario.name): the fake never wrote its ports to \(portFile.path)")
            return
        }
        let configuration = Transcriber.Configuration(key: scenario.name == "no-key" ? nil : "fake", endpoints: endpoints)
        let transcriber = Transcriber(configuration: configuration)
        let feeds = [tone() + Data(count: Int(scenario.trailingSilence * 32_000)), Data(tone().reversed())]
        var runs: [Run] = []
        if scenario.overlapping {
            let first = await hold(feeds[0], on: transcriber, prefill: 0, tail: tail)
            let second = await hold(feeds[1], on: transcriber, prefill: 0, tail: tail)
            runs = [await settle(first, tail: tail, label: "\(scenario.name) 1"), await settle(second, tail: tail, label: "\(scenario.name) 2")]
        } else {
            for index in scenario.finals.indices {
                runs.append(await settle(await hold(feeds[index], on: transcriber, prefill: 0, tail: tail), tail: tail, label: "\(scenario.name) \(index + 1)"))
            }
        }

        let output = (try? String(contentsOf: stdoutFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let captured = (try? Data(contentsOf: captureFile)) ?? Data()
        guard runs.count == 2 else {
            runs[0].captured = captured
            assess(scenario.name, scenario, runs[0], expecting: scenario.finals[0])
            return
        }
        let heardBytes = output.compactMap { line in
            line.hasSuffix(" bytes") && line.contains(" terminated ") ? line.split(separator: " ").dropLast().last.flatMap { Int($0) } : nil
        }
        let split = heardBytes.first ?? 0
        runs[0].captured = captured.prefix(split)
        runs[1].captured = captured.dropFirst(split)
        assess("\(scenario.name) session 1", scenario, runs[0], expecting: scenario.finals[0])
        assess("\(scenario.name) session 2", scenario, runs[1], expecting: scenario.finals[1])

        let (first, second) = (runs[0].lines, runs[1].lines)
        func opened(_ lines: [String]) -> [String] { lines.filter { $0.hasPrefix("transcription opened") } }
        func retries(_ lines: [String]) -> [String] { lines.filter { $0.hasPrefix("transcription retry") } }
        expect(opened(first).count == 1 && opened(first)[0].contains(" token=minted "), "\(scenario.name): session 1 opened with a minted token, got \(opened(first))")
        let expectedRetries = scenario.name == "expired-once" ? ["transcription retry session=2 reason=expiredToken"] : []
        expect(retries(first).isEmpty && retries(second) == expectedRetries, "\(scenario.name): session 2 retried \(expectedRetries.count) time(s), got \(retries(second))")
        let secondToken = scenario.name == "expired-once" ? "minted" : "reused"
        expect(opened(second).count == 1 && opened(second)[0].contains(" token=\(secondToken) "), "\(scenario.name): session 2 opened with a \(secondToken) token, got \(opened(second))")
        if scenario.name == "expired-once", let retry = second.firstIndex(where: { $0.hasPrefix("transcription retry") }),
           let open = second.firstIndex(where: { $0.hasPrefix("transcription opened") }) {
            expect(retry < open, "\(scenario.name): the retry came before session 2 opened")
        }
        let mints = output.filter { $0.hasPrefix("mint ") }.count
        let expectedMints = scenario.name == "expired-once" ? 2 : 1
        expect(mints == expectedMints, "\(scenario.name): the fake minted \(expectedMints) token(s), got \(mints)")
        if scenario.overlapping {
            let window = runs[0].window
            let firstFinal = window.firstIndex { $0.hasPrefix("transcription final session=1 ") } ?? -1
            let secondOpened = window.firstIndex { $0.hasPrefix("transcription opened session=2 ") } ?? window.count
            expect(secondOpened < firstFinal, "\(scenario.name): session 1's final landed after session 2 opened, at lines \(firstFinal) and \(secondOpened)")
        }
    }

    static func assess(_ label: String, _ scenario: Scenario, _ run: Run, expecting final: AssemblyAI.Final) {
        let lines = run.lines
        for line in lines where line.hasPrefix("transcription ") { print("  info \(line)") }
        let words = if case .heard(let text) = final { text } else { "" }

        expect(run.final == final, "\(label): delivered \(final), got \(run.final)")
        let finals = lines.filter { $0.hasPrefix("transcription final ") }
        expect(
            finals.count == 1 && finals[0].contains(" via=\(scenario.via) ") && text(of: finals[0]) == words,
            "\(label): one 'transcription final' line via \(scenario.via) with text '\(words)', got \(finals)"
        )
        if let within = scenario.deliveredWithin {
            expect(within.contains(run.deliveredAfter), "\(label): delivered \(String(format: "%.3f", run.deliveredAfter)) s after the feed ended, expected \(within)")
        }
        expect(run.shownAfterDrain == .final(final), "\(label): once the session closed the record still shows the final, got \(run.shownAfterDrain)")
        let plans = lines.filter { $0.hasPrefix("transcription finishing ") }.map { line in
            line.split(separator: " ").first { $0.hasPrefix("plan=") }.map { String($0.dropFirst(5)) } ?? line
        }
        expect(plans == (scenario.plan.map { [$0] } ?? []), "\(label): finishing plan \(scenario.plan ?? "none"), got \(plans)")
        if let plan = scenario.plan {
            let terminatedAfter = plan == "endpoint" ? run.deliveredAfter : 0
            expect(
                run.closedAfter - terminatedAfter <= 5.5,
                "\(label): the session let go \(String(format: "%.3f", run.closedAfter - terminatedAfter)) s after it sent Terminate, expected at most the 5 s drain"
            )
        }

        let hearing = run.held.shownWhileFeeding.compactMap { shown -> String? in
            if case .hearing(let text) = shown { text } else { nil }
        }
        if case .heard = final {
            let prefix = words.prefix { $0 != " " } + " frame "
            expect(hearing.allSatisfy { $0.isEmpty || $0.hasPrefix(prefix) }, "\(label): every sample while held was this session's words, \(prefix)..., got \(Set(hearing.map { $0.prefix(3) }))")
            if scenario.plan == "endpoint" {
                expect(hearing.contains { $0.hasPrefix(prefix) }, "\(label): words showed while held, the last sample read '\(hearing.last ?? "")'")
            }
        }
        if let lateTurn = scenario.lateTurn {
            let finalAt = lines.firstIndex { $0.hasPrefix("transcription final ") } ?? lines.count
            let lateAt = lines.lastIndex { $0.hasPrefix("heard ") && $0.contains(" end=true ") && text(of: $0) == lateTurn } ?? -1
            expect(finalAt < lateAt, "\(label): the server's end '\(lateTurn)' arrived after the fallback and changed nothing")
        }

        let ended = lines.filter { $0.hasPrefix("transcription ended") }
        let failed = lines.filter { $0.hasPrefix("transcription failed") }
        guard let expected = scenario.failure else {
            expect(ended.count == 1 && failed.isEmpty, "\(label): one 'transcription ended' line and no failure, got \(ended.count) and \(failed.count)")
            let numbers = ended.first.map { fields(of: $0) } ?? [:]
            expect(numbers["sent"] != nil && numbers["sent"] == numbers["server"], "\(label): the seconds sent match the seconds the server counted, \(numbers["sent"] ?? 0) and \(numbers["server"] ?? 0)")
            expectCapture(label, run)
            return
        }
        let detail = failed.map { line in line.range(of: "stage=").map { String(line[$0.lowerBound...]) } ?? line }
        expect(detail == [expected], "\(label): exactly one failure line, \(expected), got \(detail)")
        expect(ended.isEmpty, "\(label): no 'transcription ended' line, got \(ended.count)")
        let failedAt = run.held.shownWhileFeeding.firstIndex { if case .final(.failed) = $0 { true } else { false } }
        if let failedAt, failedAt < run.held.shownWhileFeeding.count - 1 {
            expect(run.held.streamTerminated, "\(label): once the session gave up, the stream refused the rest of the feed")
        }
        if label == "no-termination" { expectCapture(label, run) }
    }

    static func expectCapture(_ label: String, _ run: Run) {
        let fed = run.held.fed
        let padding = run.captured.count - fed.count
        let matches = run.captured.prefix(fed.count) == fed
            && run.captured.dropFirst(fed.count).allSatisfy { $0 == 0 }
            && (0...1600).contains(padding)
        expect(matches, "\(label): the fake received the \(fed.count) fed bytes in order plus \(padding) zero bytes of padding, \(run.captured.count) in all")
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
        let transcriber = Transcriber(configuration: Transcriber.Configuration(key: key, endpoints: .production))
        let pause = Data(count: 48_000)
        let spoken = await settle(await hold(first + pause + second, on: transcriber, prefill: prefill, tail: tail), tail: tail, label: "live")
        for line in spoken.lines where line.hasPrefix("transcription ") || line.hasPrefix("heard ") { print("  info \(line)") }
        let backlogged = prefill > 0
        let (plan, via) = backlogged ? ("terminate", "termination") : ("endpoint", "endpoint")
        expect(spoken.lines.contains { $0.hasPrefix("transcription finishing ") && $0.contains(" plan=\(plan) ") }, "live: the session finished by \(plan)")
        expect(spoken.lines.contains { $0.hasPrefix("transcription final ") && $0.contains(" via=\(via) ") }, "live: the final came via \(via)")
        if !backlogged {
            expect(spoken.deliveredAfter <= 1.5, "live: the final arrived \(String(format: "%.3f", spoken.deliveredAfter)) s after the release, expected at most 1.5 s")
            let early = spoken.held.shownWhileFeeding.contains { shown in
                if case .hearing(let text) = shown { text.hasPrefix("Open the") } else { false }
            }
            expect(early, "live: 'Open the' showed while held")
        }
        if case .heard(let sentence) = spoken.final {
            let letters = sentence.lowercased().filter(\.isLetter)
            expect(letters == "openthesettingspagethenclickthebluebuttonatthetop", "live: the final is both sentences, got '\(sentence)'")
            expect(sentence.first?.isUppercase == true && sentence.hasSuffix(".") && sentence.contains(". "), "live: the final is punctuated as two sentences, got '\(sentence)'")
        } else {
            expect(false, "live: the final is both sentences, got \(spoken.final)")
        }
        expect(!spoken.lines.contains { $0.contains("code=3007") }, "live: no 3007 input or rate violation")
        expect(spoken.lines.filter { $0.hasPrefix("transcription ended") }.count == 1, "live: one 'transcription ended' line")

        let quiet = await settle(await hold(Data(count: 64_000), on: transcriber, prefill: 0, tail: tail), tail: tail, label: "live silence")
        for line in quiet.lines where line.hasPrefix("transcription ") { print("  info \(line)") }
        expect(quiet.final == .silence, "live: 2 s of silence delivers silence, got \(quiet.final)")
        expect(quiet.lines.contains { $0.hasPrefix("transcription opened") && $0.contains(" token=reused ") }, "live: the second session reuses the token")
    }

    static func said(_ text: String, into wav: URL) -> Data? {
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", text]
        try? say.run()
        say.waitUntilExit()
        return (try? Data(contentsOf: wav)).flatMap { pcm(inWAV: $0) }
    }

    static func hold(_ pcm: Data, on transcriber: Transcriber, prefill: Double, tail: LogTail) async -> Held {
        let firstLine = tail.lines.count
        var chunks = [pcm.prefix(TapShape.firstChunk)]
        var offset = TapShape.firstChunk
        while offset < pcm.count - TapShape.converterTail {
            chunks.append(pcm[offset..<min(offset + TapShape.steadyChunk, pcm.count - TapShape.converterTail)])
            offset += TapShape.steadyChunk
        }
        chunks.append(pcm.suffix(TapShape.converterTail))

        let (starting, continuation) = start(transcriber, after: prefill)
        let sampled = prefill == 0 ? await starting.value : nil
        let early = sampled.map(outcome(of:))
        var shown: [AssemblyAI.Transcript.Shown] = []
        var streamTerminated = false
        let began = ContinuousClock.now
        for (index, chunk) in chunks.enumerated() {
            try? await Task.sleep(until: began + .milliseconds(100 * index), clock: .continuous)
            if case .terminated = continuation.yield(Data(chunk)) { streamTerminated = true }
            if let sampled { shown.append(sampled.shown) }
        }
        continuation.finish()
        let fedAt = ContinuousClock.now
        marker.notice("check fed bytes=\(pcm.count)")
        let transcription = await starting.value
        return Held(
            transcription: transcription, fed: pcm, fedAt: fedAt, firstLine: firstLine,
            shownWhileFeeding: shown, streamTerminated: streamTerminated, outcome: early ?? outcome(of: transcription)
        )
    }

    static func outcome(of transcription: Transcription) -> Task<(final: AssemblyAI.Final, deliveredAt: ContinuousClock.Instant, closedAt: ContinuousClock.Instant), Never> {
        Task {
            let final = await transcription.delivered
            let deliveredAt = ContinuousClock.now
            await transcription.closed()
            return (final, deliveredAt, ContinuousClock.now)
        }
    }

    static func settle(_ held: Held, tail: LogTail, label: String) async -> Run {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            print("  FAIL \(label): the session was still running 30 s after the feed ended")
            exit(1)
        }
        let outcome = await held.outcome.value
        watchdog.cancel()
        _ = await markAndWaitForTail(tail, "check done \(label)")
        return Run(
            held: held, final: outcome.final, deliveredAfter: held.fedAt.duration(to: outcome.deliveredAt) / .seconds(1),
            closedAfter: held.fedAt.duration(to: outcome.closedAt) / .seconds(1),
            shownAfterDrain: held.transcription.shown, window: Array(tail.lines.dropFirst(held.firstLine))
        )
    }

    static func start(_ transcriber: Transcriber, after prefill: Double) -> (Task<Transcription, Never>, SpeechStream.Continuation) {
        let (speech, continuation) = SpeechStream.makeStream(bufferingPolicy: .unbounded)
        let session = Task {
            if prefill > 0 { try? await Task.sleep(for: .seconds(prefill)) }
            return transcriber.transcribe(speech)
        }
        return (session, continuation)
    }

    static func text(of line: String) -> String {
        line.components(separatedBy: " text=").dropFirst().joined(separator: " text=")
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
            if let index = tail.lines.lastIndex(of: text) { return index }
        }
        return nil
    }

    static func endpoints(in portFile: URL) async -> AssemblyAI.Endpoints? {
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

    static func tone() -> Data {
        let nonzero: Int16 = 1
        let samples = (0..<(TapShape.firstChunk + TapShape.steadyChunk * TapShape.steadyChunkCount + TapShape.converterTail) / 2).map { index in
            Int16(8000 * sin(2 * Double.pi * 440 * Double(index) / 16_000)) | nonzero
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
