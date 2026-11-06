import AppKit
import CoreAudio

let arguments = Array(CommandLine.arguments.dropFirst())
guard let pid = arguments.first.flatMap(Int32.init) else {
    print("  FAIL no process id given")
    exit(1)
}
let capturePath = arguments.dropFirst().first
let scenarioPath = arguments.dropFirst(2).first

var failures = 0

func fail(_ message: String) {
    print("  FAIL \(message)")
    failures += 1
}

func osascript(_ source: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func driven(_ command: String) -> String {
    osascript(
        "tell application \"System Events\" to tell (first process whose unix id is \(pid)) to \(command)"
    )
}

// SwiftUI puts accessibilityLabel in AXAttributedDescription, which System
// Events cannot filter on, so the control is found as the panel's only button.
let control = "button 1 of group 1 of window 1"
let meter = "progress indicator 1 of group 1 of window 1"

func caption() -> String {
    driven("return value of static text 2 of group 1 of window 1")
}

func transcript() -> String {
    driven("return value of static text 3 of group 1 of window 1")
}

func meterSamples(_ count: Int) -> [Double] {
    let source = """
        tell application "System Events" to tell (first process whose unix id is \(pid))
        set samples to {}
        repeat \(count) times
        set end of samples to value of \(meter)
        end repeat
        return samples
        end tell
        """
    return osascript(source)
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
}

func rect(of element: String) -> CGRect? {
    let numbers = (driven("return position of \(element)") + "," + driven("return size of \(element)"))
        .split(separator: ",")
        .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard numbers.count == 4 else { return nil }
    return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
}

func post(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func wait(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

func wait(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        wait(0.1)
    }
    return condition()
}

func uint32Property(
    _ object: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> UInt32? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func deviceIsRunning() -> Bool? {
    guard let device = uint32Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
          device != 0
    else { return nil }
    return uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere).map { $0 != 0 }
}

func speakersBlocker() -> String? {
    if osascript("output muted of (get volume settings)") != "false" {
        return "the output is muted, and this check never unmutes it"
    }
    guard let output = uint32Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
          output != 0,
          uint32Property(output, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn,
          uint32Property(output, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) == 0x6973_706B
    else { return "the default output is not the built-in speakers" }
    return nil
}

let calibratedVolume = 81

func speakAndSample() -> [Double] {
    let saved = osascript("output volume of (get volume settings)")
    _ = osascript("set volume output volume \(calibratedVolume)")
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["Hello, this is a test of the level meter. One two three four five."]
    try? say.run()
    let samples = meterSamples(140)
    say.waitUntilExit()
    if let volume = Int(saved) { _ = osascript("set volume output volume \(volume)") }
    return samples
}

final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    private let process = Process()

    init() {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "ndjson",
            "--predicate",
            "subsystem == \"my.rooftop.sherpa\" AND (category == \"microphone\" OR category == \"transcription\")",
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
                    // The first line is a filter banner, not JSON.
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let message = object["eventMessage"] as? String
                    else { continue }
                    lock.withLock { messages.append(message) }
                }
            }
        }
    }

    func summary(after count: Int) -> String? {
        lock.withLock { messages.dropFirst(count).first { $0.hasPrefix("hold ended") } }
    }

    func savedPath(after count: Int) -> String? {
        lock.withLock {
            messages.dropFirst(count).first { $0.hasPrefix("wav saved") }
                .flatMap { line in line.range(of: "path=").map { String(line[$0.upperBound...]) } }
        }
    }

    func loudest(after count: Int) -> Double? {
        lock.withLock {
            messages.dropFirst(count)
                .filter { $0.hasPrefix("buffer ") }
                .compactMap { fields(of: $0)["dBFS"] }
                .max()
        }
    }

    func lines(after count: Int) -> [String] {
        lock.withLock { Array(messages.dropFirst(count)) }
    }

    var count: Int { lock.withLock { messages.count } }

    func stop() { process.terminate() }
}

func fields(of line: String) -> [String: Double] {
    var result: [String: Double] = [:]
    for pair in line.split(separator: " ") {
        let parts = pair.split(separator: "=")
        if parts.count == 2, let number = Double(parts[1]) { result[String(parts[0])] = number }
    }
    return result
}

enum Hold {
    case still
    case draggedOff
    case speakersTalking
}

func checkMeter(_ label: String, _ hold: Hold, samples: [Double], released: Double?, loudest: Double?) {
    let heard = loudest.map { String(format: "%.1f dBFS", $0) } ?? "no buffer lines"
    let peak = samples.max()
    let shown = peak.map { "\(Int(($0 * 100).rounded())) %" } ?? "no reading"
    if !samples.isEmpty { print("  info \(label): the bar peaked at \(shown), the loudest buffer was \(heard)") }

    switch hold {
    case .still:
        if let peak, peak <= 0.10 {
            print("  ok   \(label): the bar stayed near empty in silence")
        } else {
            fail("\(label): in silence the bar reached \(shown), expected at most 10 %; the loudest buffer was \(heard), is the room quiet?")
        }
    case .speakersTalking:
        if let peak, peak >= 0.15 {
            print("  ok   \(label): the bar rose to \(shown) while the speakers talked")
        } else {
            fail("\(label): while say played the bar reached \(shown), expected at least 15 %; the loudest buffer was \(heard)")
        }
    case .draggedOff:
        break
    }

    if released == 0 {
        print("  ok   \(label): the bar is empty after the mouse-up")
    } else {
        fail("\(label): after the mouse-up the bar read \(released.map { "\($0)" } ?? "nothing"), expected 0")
    }
}

func afinfo(_ path: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    process.arguments = [path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

func loudestWindowDBFS(_ samples: [Int16]) -> Double {
    let window = 1600
    var squares = [Double](repeating: 0, count: samples.count + 1)
    for (index, sample) in samples.enumerated() { squares[index + 1] = squares[index] + Double(sample) * Double(sample) }
    var loudest = 0.0
    for start in stride(from: 0, through: max(samples.count - window, 0), by: 160) {
        let end = min(start + window, samples.count)
        loudest = max(loudest, ((squares[end] - squares[start]) / Double(end - start)).squareRoot())
    }
    return 20 * log10(max(loudest / 32768, 1e-6))
}

func checkWAV(_ label: String, _ kind: Hold, frames: Double, rate: Double, loudest: Double?, logged: Int) {
    _ = wait(upTo: 2) { tail.savedPath(after: logged) != nil }
    guard let path = tail.savedPath(after: logged) else {
        fail("\(label): no 'wav saved' line in the log")
        return
    }
    let info = afinfo(path)
    let required = ["File type ID:   WAVE", "Data format:     1 ch,  16000 Hz, Int16", "audio data file offset: 44"]
    let missing = required.filter { !info.contains($0) }
    let duration = info.components(separatedBy: "estimated duration: ").dropFirst().first
        .flatMap { $0.split(separator: " ").first }.flatMap { Double($0) }
    let expected = frames / rate
    guard missing.isEmpty, let duration, abs(duration - expected) <= 0.05 else {
        let reported = duration.map { String(format: "%.3f", $0) } ?? "none"
        fail("\(label): afinfo on \(path) lacked \(missing), duration \(reported) s against \(String(format: "%.3f", expected)) s from the tap")
        return
    }
    print("  ok   \(label): last-hold.wav is PCM16 mono 16 kHz with a 44-byte header, \(String(format: "%.2f", duration)) s")

    guard let data = FileManager.default.contents(atPath: path), data.count > 44 else {
        fail("\(label): \(path) has no samples after the header")
        return
    }
    let samples = data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let saved = loudestWindowDBFS(samples)
    let tapped = loudest.map { String(format: "%.1f dBFS", $0) } ?? "no buffer lines"
    print("  info \(label): the loudest 100 ms of the file is \(String(format: "%.1f", saved)) dBFS, the loudest tap buffer \(tapped)")
    guard kind != .draggedOff else { return }
    if let loudest, abs(saved - loudest) <= 3 {
        print("  ok   \(label): the file is as loud as the tap, within 3 dB")
    } else {
        fail("\(label): the file's loudest 100 ms is \(String(format: "%.1f", saved)) dBFS, expected within 3 dB of the tap's \(tapped)")
    }
}

struct Delivered {
    let session: Int
    let via: String
    let text: String
}

func finals(in lines: [String]) -> [Delivered] {
    lines.compactMap { line in
        guard line.hasPrefix("transcription final ") else { return nil }
        let parts = line.components(separatedBy: " text=")
        var head: [String: String] = [:]
        for pair in parts[0].split(separator: " ") {
            let field = pair.split(separator: "=", maxSplits: 1)
            if field.count == 2 { head[String(field[0])] = String(field[1]) }
        }
        guard let session = head["session"].flatMap({ Int($0) }), let via = head["via"] else { return nil }
        return Delivered(session: session, via: via, text: parts.dropFirst().joined(separator: " text="))
    }
}

func closed(after count: Int) -> Int {
    tail.lines(after: count).filter { $0.hasPrefix("transcription ended") || $0.hasPrefix("transcription failed") }.count
}

func useScenario(_ name: String) {
    guard let scenarioPath else { return }
    try? Data("\(name)\n".utf8).write(to: URL(fileURLWithPath: scenarioPath))
}

func checkPanel(_ label: String, logged: Int) {
    guard capturePath != nil else { return }
    _ = wait(upTo: 4) { !finals(in: tail.lines(after: logged)).isEmpty }
    let delivered = finals(in: tail.lines(after: logged))
    guard delivered.count == 1, let final = delivered.first else {
        fail("\(label): expected one 'transcription final' line after the release, got \(delivered.count)")
        return
    }
    let closedTurns = final.text.range(of: #"^S\d+ T\d+ frame \d+\.( S\d+ T\d+ frame \d+\.)*$"#, options: .regularExpression) != nil
    if ["endpoint", "termination"].contains(final.via), closedTurns {
        print("  ok   \(label): one final via \(final.via), every turn closed by its period: '\(final.text)'")
    } else {
        fail("\(label): the final came via \(final.via) as '\(final.text)', expected the endpoint answer or Termination with every turn closed by its period")
    }
    if wait(upTo: 1, until: { transcript() == final.text }) {
        print("  ok   \(label): the panel shows the final")
    } else {
        fail("\(label): the panel read '\(transcript())', expected the final '\(final.text)'")
    }
    _ = wait(upTo: 6) { closed(after: logged) > 0 }
    let drained = transcript()
    if drained == final.text {
        print("  ok   \(label): the panel still shows the final after the session closed")
    } else {
        fail("\(label): after the session closed the panel read '\(drained)', expected the final '\(final.text)'")
    }
}

func captureSize() -> Int {
    capturePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? 0
}

func checkTranscription(_ label: String, logged: Int, captureOffset: Int) {
    guard let capturePath else { return }
    _ = wait(upTo: 8) {
        tail.lines(after: logged).contains { $0.hasPrefix("transcription ended") || $0.hasPrefix("transcription failed") }
    }
    let lines = tail.lines(after: logged)
    for line in lines where line.hasPrefix("transcription ") { print("  info \(label): \(line)") }
    let release = lines.firstIndex { $0.hasPrefix("hold ended") } ?? lines.count
    let early = lines.prefix(release).filter { $0.hasPrefix("heard ") }.count
    if early > 0 {
        print("  ok   \(label): \(early) heard lines arrived while the control was still held")
    } else {
        fail("\(label): no heard line arrived before the 'hold ended' line")
    }
    let ended = lines.dropFirst(release).filter { $0.hasPrefix("transcription ended") }.count
    let failed = lines.filter { $0.hasPrefix("transcription failed") }.count
    if ended == 1, failed == 0 {
        print("  ok   \(label): the session ended once after the release, with no failure")
    } else {
        fail("\(label): after the release there were \(ended) 'transcription ended' and \(failed) 'transcription failed' lines, expected 1 and 0")
    }
    guard let wavPath = tail.savedPath(after: logged),
          let wav = FileManager.default.contents(atPath: wavPath),
          let capture = FileManager.default.contents(atPath: capturePath)
    else {
        fail("\(label): could not read both last-hold.wav and the fake's capture at \(capturePath)")
        return
    }
    let saved = wav.dropFirst(44)
    let sent = capture.dropFirst(captureOffset)
    let padding = sent.count - saved.count
    if sent.prefix(saved.count) == saved, sent.dropFirst(saved.count).allSatisfy({ $0 == 0 }), (0...1600).contains(padding) {
        print("  ok   \(label): the fake received last-hold.wav's \(saved.count) bytes in order plus \(padding) zero bytes of padding")
    } else {
        fail("\(label): the fake received \(sent.count) bytes that are not last-hold.wav's \(saved.count) bytes plus at most 1600 zero bytes")
    }
}

guard let controlRect = rect(of: control) else {
    print("  FAIL the hold-to-talk control is not in the panel, is the panel open?")
    exit(1)
}
if caption() == "Microphone access is off" {
    print("  FAIL microphone access is off for Sherpa, enable it in System Settings > Privacy & Security > Microphone")
    exit(1)
}
guard let runningBefore = deviceIsRunning() else {
    print("  skip hold to talk: there is no default input device to read")
    exit(0)
}
guard !runningBefore else {
    print("  skip hold to talk: another app is already using the microphone, so the device flag says nothing about this one")
    exit(0)
}

let tail = LogTail()
wait(1)

let centre = CGPoint(x: controlRect.midX, y: controlRect.midY)
let cursor = CGEvent(source: nil)?.location ?? centre

func finish() -> Never {
    tail.stop()
    CGWarpMouseCursorPosition(cursor)
    exit(failures == 0 ? 0 : 1)
}

func hold(_ label: String, _ kind: Hold) {
    if kind == .speakersTalking, let reason = speakersBlocker() {
        print("  skip \(label): \(reason)")
        return
    }
    let logged = tail.count
    let captureOffset = captureSize()
    CGWarpMouseCursorPosition(centre)
    wait(0.2)
    post(.leftMouseDown, at: centre)
    var release = centre

    if wait(upTo: 1, until: { caption() == "Allow microphone access to talk" }) {
        post(.leftMouseUp, at: release)
        fail("\(label): macOS is asking for microphone access, click Allow, then rerun")
        finish()
    }
    var samples: [Double] = []
    if kind == .still { samples = meterSamples(45) } else { wait(1.5) }
    let listening = caption()
    let running = deviceIsRunning() == true
    if listening != "Listening…" || !running {
        post(.leftMouseUp, at: release)
        fail("\(label): after 1.5 s the caption read '\(listening)' and the device running was \(running)")
        return
    }

    if capturePath != nil {
        if wait(upTo: 1.5, until: { transcript().hasPrefix("S") }) {
            print("  ok   \(label): words showed while held: '\(transcript())'")
        } else {
            fail("\(label): no words showed while held, the panel read '\(transcript())'")
        }
    }

    if kind == .speakersTalking { samples = speakAndSample() }

    if kind == .draggedOff {
        let screenWidth = NSScreen.screens.first?.frame.width ?? 0
        let offset: CGFloat = centre.x + 200 < screenWidth ? 200 : -200
        release = CGPoint(x: centre.x + offset, y: centre.y)
        post(.leftMouseDragged, at: release)
        wait(0.5)
        let afterDrag = caption()
        if afterDrag != "Listening…" || deviceIsRunning() != true {
            post(.leftMouseUp, at: release)
            fail("\(label): dragging off the control ended the hold, caption '\(afterDrag)'")
            return
        }
    }

    post(.leftMouseUp, at: release)
    let stopped = wait(upTo: 2) { deviceIsRunning() == false && caption() == "Hold to talk" }
    guard stopped else {
        fail("\(label): 2 s after the mouse-up the device running was \(deviceIsRunning() as Any) and the caption '\(caption())'")
        return
    }
    print("  ok   \(label): the device stopped after the mouse-up")
    let released = meterSamples(1).first

    _ = wait(upTo: 2) { tail.summary(after: logged) != nil }
    guard let line = tail.summary(after: logged) else {
        fail("\(label): no 'hold ended' line in the log")
        return
    }
    let values = fields(of: line)
    guard let frames = values["frames"], let buffers = values["buffers"], let rate = values["rate"],
          let seconds = values["seconds"], let firstBuffer = values["firstBuffer"]
    else {
        fail("\(label): the summary '\(line)' has no frames, buffers, rate, seconds and firstBuffer")
        return
    }
    let flowing = seconds - firstBuffer
    let ratio = flowing > 0 ? frames / (rate * flowing) : 0
    print("  info \(label): \(line)")
    if buffers >= 3, (0.7...1.1).contains(ratio) {
        print("  ok   \(label): \(Int(frames)) frames at \(Int(rate)) Hz, ratio \(String(format: "%.2f", ratio))")
    } else {
        fail("\(label): \(Int(buffers)) buffers and ratio \(String(format: "%.2f", ratio)), expected at least 3 and 0.7 to 1.1")
    }
    let loudest = tail.loudest(after: logged)
    checkMeter(label, kind, samples: samples, released: released, loudest: loudest)
    checkWAV(label, kind, frames: frames, rate: rate, loudest: loudest, logged: logged)
    checkPanel(label, logged: logged)
    checkTranscription(label, logged: logged, captureOffset: captureOffset)
}

func press() {
    CGWarpMouseCursorPosition(centre)
    wait(0.2)
    post(.leftMouseDown, at: centre)
}

func release() {
    post(.leftMouseUp, at: centre)
}

func silentHold() {
    guard capturePath != nil, scenarioPath != nil else { return }
    let label = "silent hold"
    useScenario("silent")
    defer { useScenario("ok") }
    let logged = tail.count
    press()
    wait(1.5)
    release()
    if wait(upTo: 3, until: { transcript() == "Didn't catch that" }) {
        print("  ok   \(label): the panel reads 'Didn't catch that'")
    } else {
        fail("\(label): the panel read '\(transcript())', expected 'Didn't catch that'")
    }
    _ = wait(upTo: 6) { closed(after: logged) > 0 }
}

func pressAgainWhileFinishing() {
    guard capturePath != nil else { return }
    let label = "press again while the last hold finishes"
    let logged = tail.count
    press()
    wait(3)
    release()
    wait(0.3)
    guard finals(in: tail.lines(after: logged)).isEmpty else {
        fail("\(label): the first hold's final landed within 0.3 s of its release, so the next press cannot overlap it")
        _ = wait(upTo: 6) { closed(after: logged) > 0 }
        return
    }
    press()
    if wait(upTo: 0.3, until: { transcript().isEmpty }) {
        print("  ok   \(label): the press cleared the panel")
    } else {
        fail("\(label): 0.3 s after the press the panel still read '\(transcript())'")
    }
    var samples: [String] = []
    for _ in 0..<10 {
        samples.append(transcript())
        wait(0.2)
    }
    release()
    _ = wait(upTo: 8) { closed(after: logged) >= 2 }

    let lines = tail.lines(after: logged)
    let delivered = finals(in: lines).sorted { $0.session < $1.session }
    guard delivered.count == 2 else {
        fail("\(label): expected a final from each hold, got \(delivered.map(\.text))")
        return
    }
    let (first, second) = (delivered[0], delivered[1])
    let secondBegan = lines.indices.filter { lines[$0].hasPrefix("hold began") }.dropFirst().first ?? lines.count
    let firstFinal = lines.firstIndex { $0.hasPrefix("transcription final session=\(first.session) ") } ?? -1
    if firstFinal > secondBegan {
        print("  ok   \(label): the first hold's final landed during the second hold")
    } else {
        fail("\(label): the first hold's final landed before the second hold began, so nothing overlapped")
    }
    let firstWords = first.text.prefix { $0 != " " } + " "
    let leaked = samples.filter { $0.hasPrefix(firstWords) }
    if leaked.isEmpty {
        print("  ok   \(label): no sample during the second hold showed the first hold's words, \(Set(samples))")
    } else {
        fail("\(label): the panel showed the first hold's words during the second hold: \(leaked)")
    }
    if wait(upTo: 1, until: { transcript() == second.text }) {
        print("  ok   \(label): the panel ends on the second hold's final '\(second.text)'")
    } else {
        fail("\(label): the panel read '\(transcript())', expected the second hold's final '\(second.text)'")
    }
}

hold("plain hold", .still)
wait(0.5)
hold("hold dragged off the control", .draggedOff)
wait(0.5)
hold("hold while the speakers talk", .speakersTalking)
wait(0.5)
silentHold()
wait(0.5)
pressAgainWhileFinishing()
finish()
