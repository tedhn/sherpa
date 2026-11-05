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
    let expectedFailure: String?
}

enum TapShape {
    static let firstChunk = 2752
    static let steadyChunk = 3200
    static let steadyChunkCount = 28
    static let converterTail = 440
}

struct Run {
    let lines: [String]
    let fed: Data
    let streamTerminated: Bool
    let returnedBeforeFeedEnded: Bool
    var captured = Data()
}

@main
enum TranscriptionCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let scenarios = [
        Scenario(name: "ok", expectedFailure: nil),
        Scenario(name: "close-1008", expectedFailure: "stage=connecting reason=serverError code=1008 detail=Unauthorized Connection: Invalid API key"),
        Scenario(name: "no-begin", expectedFailure: "stage=connecting reason=timedOut"),
        Scenario(name: "no-termination", expectedFailure: "stage=closing reason=timedOut"),
        Scenario(name: "token-401", expectedFailure: #"stage=minting reason=tokenRefused status=401 detail={"error":"Invalid API key"}"#),
        Scenario(name: "no-key", expectedFailure: "stage=minting reason=noAPIKey"),
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
        let server = Process()
        server.executableURL = URL(fileURLWithPath: fake)
        server.arguments = [portFile.path, captureFile.path, scenario.name == "no-key" ? "ok" : scenario.name]
        server.standardOutput = FileHandle.nullDevice
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
        var run = await feed(tone(), to: Transcriber(configuration: configuration), tail: tail, prefill: 0, label: scenario.name)
        run.captured = (try? Data(contentsOf: captureFile)) ?? Data()
        assess(scenario, run)
    }

    static func assess(_ scenario: Scenario, _ run: Run) {
        let label = scenario.name
        let ended = run.lines.filter { $0.hasPrefix("transcription ended") }
        let failed = run.lines.filter { $0.hasPrefix("transcription failed") }
        for line in run.lines where line.hasPrefix("transcription ") { print("  info \(line)") }

        guard let expected = scenario.expectedFailure else {
            let fedAt = run.lines.firstIndex { $0.hasPrefix("check fed") } ?? run.lines.count
            let heard = run.lines.prefix(fedAt).filter { $0.hasPrefix("heard ") }
            expect(!heard.isEmpty, "\(label): \(heard.count) heard lines arrived before the feed finished")
            expect(ended.count == 1 && failed.isEmpty, "\(label): one 'transcription ended' line and no failure, got \(ended.count) and \(failed.count)")
            let numbers = ended.first.map { fields(of: $0) } ?? [:]
            expect(numbers["sent"] != nil && numbers["sent"] == numbers["server"], "\(label): the seconds sent match the seconds the server counted, \(numbers["sent"] ?? 0) and \(numbers["server"] ?? 0)")
            expectCapture(label, run)
            return
        }
        let detail = failed.map { line in line.range(of: "stage=").map { String(line[$0.lowerBound...]) } ?? line }
        expect(detail == [expected], "\(label): exactly one failure line, \(expected), got \(detail)")
        expect(ended.isEmpty, "\(label): no 'transcription ended' line, got \(ended.count)")
        if run.returnedBeforeFeedEnded {
            expect(run.streamTerminated, "\(label): once the session gave up, the stream refused the rest of the feed")
        }
        if label == "no-termination" { expectCapture(label, run) }
    }

    static func expectCapture(_ label: String, _ run: Run) {
        let padding = run.captured.count - run.fed.count
        let matches = run.captured.prefix(run.fed.count) == run.fed
            && run.captured.dropFirst(run.fed.count).allSatisfy { $0 == 0 }
            && (0...1600).contains(padding)
        expect(matches, "\(label): the fake received the \(run.fed.count) fed bytes in order plus \(padding) zero bytes of padding, \(run.captured.count) in all")
    }

    static func checkLive(tail: LogTail, workspace: URL, prefill: Double) async {
        print("live\(prefill > 0 ? " with \(prefill) s prefilled" : "")")
        guard let key = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"], !key.isEmpty else {
            expect(false, "live: ASSEMBLYAI_API_KEY is not set")
            return
        }
        let wav = workspace.appending(path: "live.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", "one two three four five six seven eight nine ten"]
        try? say.run()
        say.waitUntilExit()
        guard let speech = (try? Data(contentsOf: wav)).flatMap(pcm(inWAV:)) else {
            expect(false, "live: say did not write a 16 kHz PCM16 WAV to \(wav.path)")
            return
        }
        let configuration = Transcriber.Configuration(key: key, endpoints: .production)
        let oneSecondOfSilence = Data(count: 32_000)
        let run = await feed(speech + oneSecondOfSilence, to: Transcriber(configuration: configuration), tail: tail, prefill: prefill, label: "live")
        for line in run.lines where line.hasPrefix("transcription ") || line.hasPrefix("heard ") { print("  info \(line)") }
        let fedAt = run.lines.firstIndex { $0.hasPrefix("check fed") } ?? run.lines.count
        func text(_ line: String) -> String { line.components(separatedBy: " text=").dropFirst().joined(separator: " text=") }
        let latencyIsMeasurable = prefill == 0
        if latencyIsMeasurable {
            let heardEarly = run.lines.prefix(fedAt).contains { $0.hasPrefix("heard ") && !text($0).isEmpty }
            expect(heardEarly, "live: a heard line with text arrived before the feed finished")
        }
        let last = run.lines.last { $0.hasPrefix("heard ") && $0.contains(" end=true ") && !text($0).isEmpty }
        let spoken = last.map { text($0).lowercased().filter { $0.isLetter || $0.isNumber } }
        expect(
            spoken == "12345678910" || spoken == "onetwothreefourfivesixseveneightnineten",
            "live: the last ended turn is the ten numbers, got \(spoken ?? "none")"
        )
        expect(!run.lines.contains { $0.contains("code=3007") }, "live: no 3007 input or rate violation")
        expect(run.lines.filter { $0.hasPrefix("transcription ended") }.count == 1, "live: one 'transcription ended' line")
    }

    static func feed(_ pcm: Data, to transcriber: Transcriber, tail: LogTail, prefill: Double, label: String) async -> Run {
        let first = tail.lines.count
        var chunks = [pcm.prefix(TapShape.firstChunk)]
        var offset = TapShape.firstChunk
        while offset < pcm.count - TapShape.converterTail {
            chunks.append(pcm[offset..<min(offset + TapShape.steadyChunk, pcm.count - TapShape.converterTail)])
            offset += TapShape.steadyChunk
        }
        chunks.append(pcm.suffix(TapShape.converterTail))

        let (session, continuation) = start(transcriber, after: prefill)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            print("  FAIL \(label): the session was still running 30 s after it began")
            exit(1)
        }
        var streamTerminated = false
        let began = ContinuousClock.now
        for (index, chunk) in chunks.enumerated() {
            try? await Task.sleep(until: began + .milliseconds(100 * index), clock: .continuous)
            if case .terminated = continuation.yield(Data(chunk)) { streamTerminated = true }
        }
        continuation.finish()
        let fedAt = ContinuousClock.now
        marker.notice("check fed bytes=\(pcm.count)")
        let returnedAt = await session.value
        watchdog.cancel()
        _ = await markAndWaitForTail(tail, "check done \(label)")
        return Run(lines: Array(tail.lines.dropFirst(first)), fed: pcm, streamTerminated: streamTerminated, returnedBeforeFeedEnded: returnedAt < fedAt)
    }

    static func start(_ transcriber: Transcriber, after prefill: Double) -> (Task<ContinuousClock.Instant, Never>, SpeechStream.Continuation) {
        let (speech, continuation) = SpeechStream.makeStream(bufferingPolicy: .unbounded)
        let session = Task {
            try? await Task.sleep(for: .seconds(prefill))
            await transcriber.transcribe(speech)
            return ContinuousClock.now
        }
        return (session, continuation)
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
