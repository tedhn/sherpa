import AppKit
import CoreAudio

let arguments = Array(CommandLine.arguments.dropFirst())
guard let pid = arguments.first.flatMap(Int32.init) else {
    print("  FAIL no process id given")
    exit(1)
}
let capturePath = arguments.dropFirst().first
let scenarioPath = arguments.dropFirst(2).first
let idleSeconds = arguments.dropFirst(3).first.flatMap(Double.init)
let archivePath = arguments.dropFirst(4).first

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
    private var stamps: [Date] = []
    private let process = Process()

    init() {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "ndjson",
            "--predicate",
            "subsystem == \"my.rooftop.sherpa\" AND (category == \"microphone\" OR category == \"transcription\" OR category == \"screenshot\")",
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
                    // The first line is a filter banner, not JSON.
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let message = object["eventMessage"] as? String
                    else { continue }
                    let at = (object["timestamp"] as? String).flatMap(stamp.date(from:)) ?? Date()
                    lock.withLock {
                        messages.append(message)
                        stamps.append(at)
                    }
                }
            }
        }
    }

    func summary(after count: Int) -> String? {
        lock.withLock { messages.dropFirst(count).first { $0.hasPrefix("hold ended") } }
    }

    func savedPath(after count: Int) -> String? {
        lock.withLock {
            messages.dropFirst(count).last { $0.hasPrefix("wav saved") }
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

    func time(of prefix: String, after count: Int) -> Date? {
        lock.withLock {
            messages.indices.dropFirst(count).first { messages[$0].hasPrefix(prefix) }.map { stamps[$0] }
        }
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
    let utterance: Int
    let holds: Int
    let text: String
}

func deliveries(in lines: [String]) -> [Delivered] {
    lines.compactMap { line in
        guard line.hasPrefix("transcription delivered ") else { return nil }
        let parts = line.components(separatedBy: " text=")
        var head: [String: Int] = [:]
        for pair in parts[0].split(separator: " ") {
            let field = pair.split(separator: "=", maxSplits: 1)
            if field.count == 2, let number = Int(field[1]) { head[String(field[0])] = number }
        }
        guard let session = head["session"], let utterance = head["utterance"], let holds = head["holds"] else { return nil }
        return Delivered(session: session, utterance: utterance, holds: holds, text: parts.dropFirst().joined(separator: " text="))
    }
}

func sessionLines(after count: Int) -> [String] {
    tail.lines(after: count).filter { line in
        ["transcription connecting", "transcription opened", "transcription closing", "transcription ended", "transcription failed"].contains { line.hasPrefix($0) }
    }
}

func useScenario(_ name: String) {
    guard let scenarioPath else { return }
    try? Data("\(name)\n".utf8).write(to: URL(fileURLWithPath: scenarioPath))
}

let closedTurns = #"^S\d+ T\d+ frame \d+\.( S\d+ T\d+ frame \d+\.)*$"#

@discardableResult
func checkPanel(_ label: String, logged: Int, releasedAt: Date, holds: Int = 1) -> Delivered? {
    guard capturePath != nil else { return nil }
    _ = wait(upTo: 4) { !deliveries(in: tail.lines(after: logged)).isEmpty }
    let delivered = deliveries(in: tail.lines(after: logged))
    guard delivered.count == 1, let utterance = delivered.first else {
        fail("\(label): expected one 'transcription delivered' line after the release, got \(delivered.count)")
        return nil
    }
    let after = tail.time(of: "transcription delivered ", after: logged).map { $0.timeIntervalSince(releasedAt) } ?? -1
    if (2.0...2.6).contains(after) {
        print("  ok   \(label): delivered once, \(String(format: "%.2f", after)) s after the mouse-up")
    } else {
        fail("\(label): delivered \(String(format: "%.2f", after)) s after the mouse-up, expected 2.0 to 2.6, the 1 s merge window plus the fake's 1 s answer")
    }
    if utterance.holds == holds, utterance.text.range(of: closedTurns, options: .regularExpression) != nil {
        print("  ok   \(label): \(holds) hold(s), every turn closed by its period: '\(utterance.text)'")
    } else {
        fail("\(label): delivered \(utterance.holds) hold(s) as '\(utterance.text)', expected \(holds) with every turn closed by its period")
    }
    if wait(upTo: 1, until: { transcript() == utterance.text }) {
        print("  ok   \(label): the panel shows the delivered text")
    } else {
        fail("\(label): the panel read '\(transcript())', expected '\(utterance.text)'")
    }
    checkArchive(label, utterance, holds: holds, logged: logged)
    return utterance
}

var checkedRows: Set<String> = []

func checkArchive(_ label: String, _ delivered: Delivered, holds: Int, logged: Int) {
    guard let archivePath else { return }
    let directory = URL(fileURLWithPath: archivePath)
    func rows() -> [(name: String, row: [String: Any])] {
        ((try? FileManager.default.contentsOfDirectory(atPath: archivePath)) ?? [])
            .filter { $0.hasSuffix(".json") && !checkedRows.contains($0) }
            .compactMap { name in
                let row = (try? Data(contentsOf: directory.appending(path: name)))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return row.flatMap { $0["final_text"] as? String == delivered.text ? (name, $0) : nil }
            }
    }
    _ = wait(upTo: 3) { !rows().isEmpty }
    let found = rows()
    guard found.count == 1, let (name, row) = found.first else {
        fail("\(label): expected one new archive row with final_text '\(delivered.text)', got \(found.count)")
        return
    }
    checkedRows.insert(name)
    print("  ok   \(label): the archive took one row for the delivered text")
    if row["holds"] as? Int == holds {
        print("  ok   \(label): the row counts \(holds) hold(s)")
    } else {
        fail("\(label): the row counts \(row["holds"] ?? "no") hold(s), expected \(holds)")
    }
    guard let audioPath = row["audio_path"] as? String,
          let wav = FileManager.default.contents(atPath: directory.appending(path: audioPath).path)
    else {
        fail("\(label): the row's audio_path \(row["audio_path"] ?? "null") names no WAV in the archive")
        return
    }
    let info = afinfo(directory.appending(path: audioPath).path)
    let required = ["File type ID:   WAVE", "Data format:     1 ch,  16000 Hz, Int16", "audio data file offset: 44"]
    let missing = required.filter { !info.contains($0) }
    if missing.isEmpty {
        print("  ok   \(label): \(audioPath) is PCM16 mono 16 kHz with a 44-byte header")
    } else {
        fail("\(label): afinfo on \(audioPath) lacked \(missing)")
    }
    let pcm = wav.dropFirst(44)
    if row["audio_ms"] as? Int == pcm.count / 32 {
        print("  ok   \(label): audio_ms is \(pcm.count / 32), the WAV's PCM at 32 bytes per ms")
    } else {
        fail("\(label): audio_ms is \(row["audio_ms"] ?? "null"), expected \(pcm.count / 32) from \(pcm.count) PCM bytes")
    }
    guard let lastPath = tail.savedPath(after: logged), let last = FileManager.default.contents(atPath: lastPath)?.dropFirst(44) else {
        fail("\(label): could not read last-hold.wav to compare with the archive")
        return
    }
    if holds == 1 ? pcm == last : pcm.suffix(last.count) == last {
        print("  ok   \(label): the archived PCM \(holds == 1 ? "equals" : "ends with") last-hold.wav's \(last.count) bytes")
    } else {
        fail("\(label): the archived \(pcm.count) PCM bytes \(holds == 1 ? "differ from" : "do not end with") last-hold.wav's \(last.count) bytes")
    }
}

func captureSize() -> Int {
    capturePath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int } ?? 0
}

func checkTranscription(_ label: String, logged: Int, captureOffset: Int) {
    guard let capturePath else { return }
    let lines = tail.lines(after: logged)
    for line in lines where line.hasPrefix("transcription ") { print("  info \(label): \(line)") }
    let release = lines.firstIndex { $0.hasPrefix("hold ended") } ?? lines.count
    let early = lines.prefix(release).filter { $0.hasPrefix("heard ") }.count
    if early > 0 {
        print("  ok   \(label): \(early) heard lines arrived while the control was still held")
    } else {
        fail("\(label): no heard line arrived before the 'hold ended' line")
    }
    let session = sessionLines(after: logged)
    if session.isEmpty {
        print("  ok   \(label): the open session carried the hold, with no connect, close or failure")
    } else {
        fail("\(label): the hold touched the session itself: \(session)")
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

func checkScreenshots(logged: Int) {
    guard capturePath != nil else { return }
    let label = "plain hold screenshots"
    guard let utterance = deliveries(in: tail.lines(after: logged)).first?.utterance else {
        fail("\(label): no 'transcription delivered' line to follow")
        return
    }
    let handoffPrefix = "transcription screenshots utterance=\(utterance) "
    _ = wait(upTo: 5) { tail.lines(after: logged).contains { $0.hasPrefix(handoffPrefix) } }
    let lines = tail.lines(after: logged)
    guard let handoffAt = lines.firstIndex(where: { $0.hasPrefix(handoffPrefix) }) else {
        fail("\(label): no '\(handoffPrefix)' line after the delivery")
        return
    }
    let deliveredAt = lines.firstIndex { $0.hasPrefix("transcription delivered ") } ?? lines.count
    let handoff = lines[handoffAt]
    if deliveredAt < handoffAt {
        print("  ok   \(label): the handoff followed the delivery: '\(handoff)'")
    } else {
        fail("\(label): the handoff '\(handoff)' came before the delivery, at lines \(handoffAt) and \(deliveredAt)")
    }
    if lines.contains(where: { $0.hasPrefix("screenshots failed reason=noAccess") }) {
        print("  skip screenshots: allow Sherpa in System Settings > Privacy & Security > Screen Recording, then rerun")
        if handoff == "\(handoffPrefix)displays=none" {
            print("  ok   \(label): a denied capture still delivered, and the handoff read displays=none")
        } else {
            fail("\(label): with Screen Recording denied the handoff read '\(handoff)', expected '\(handoffPrefix)displays=none'")
        }
        return
    }
    let taken = lines.filter { $0.hasPrefix("screenshot taken ") }.map { line in
        Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { pair -> (String, String)? in
            let field = pair.split(separator: "=", maxSplits: 1)
            return field.count == 2 ? (String(field[0]), String(field[1])) : nil
        })
    }
    let screens = Set(NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
    let ids = taken.compactMap { $0["display"].flatMap(UInt32.init) }
    if taken.count == screens.count {
        print("  ok   \(label): \(taken.count) 'screenshot taken' line(s), one per screen")
    } else {
        fail("\(label): \(taken.count) 'screenshot taken' line(s) for \(screens.count) screen(s)")
    }
    if Set(ids) == screens, ids.count == taken.count {
        print("  ok   \(label): the display ids are the NSScreenNumber set \(screens.sorted())")
    } else {
        fail("\(label): the display ids \(ids) are not the NSScreenNumber set \(screens.sorted())")
    }
    let longest = taken.compactMap { $0["pixels"]?.split(separator: "x").compactMap { Int($0) }.max() }
    if longest.count == taken.count, longest.allSatisfy({ $0 <= 1280 }) {
        print("  ok   \(label): every longer axis is at most 1280, got \(longest)")
    } else {
        fail("\(label): the longer axes \(longest) are not all at most 1280")
    }
    if handoff == "\(handoffPrefix)displays=\(screens.count)" {
        print("  ok   \(label): the handoff read displays=\(screens.count)")
    } else {
        fail("\(label): the handoff read '\(handoff)', expected displays=\(screens.count)")
    }
}

func panelWindows() -> String {
    driven("return count of windows")
}

func clickStatusItem(expecting windows: String) -> Bool {
    _ = driven("click menu bar item 1 of menu bar 2")
    return wait(upTo: 5) { panelWindows() == windows }
}

func lastSession(after count: Int) -> Int? {
    tail.lines(after: count).compactMap { line -> Int? in
        guard line.hasPrefix("transcription opened session=") else { return nil }
        return line.split(separator: " ").first { $0.hasPrefix("session=") }.flatMap { Int($0.dropFirst(8)) }
    }.last
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
    let releasedAt = Date()
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
    checkPanel(label, logged: logged, releasedAt: releasedAt)
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

func talk(for seconds: Double) -> Date {
    press()
    wait(seconds)
    release()
    return Date()
}

func samples(_ count: Int) -> [String] {
    (0..<count).map { _ in
        defer { wait(0.2) }
        return transcript()
    }
}

func warmFirst() -> Int? {
    guard capturePath != nil, let idleSeconds else { return nil }
    let label = "panel open"
    guard clickStatusItem(expecting: "0") else {
        fail("\(label): the panel did not close")
        return nil
    }
    wait(idleSeconds + 1.5)
    let logged = tail.count
    guard clickStatusItem(expecting: "1") else {
        fail("\(label): the panel did not reopen")
        return nil
    }
    _ = wait(upTo: 3) { lastSession(after: logged) != nil }
    let lines = tail.lines(after: logged)
    guard let session = lastSession(after: logged),
          lines.contains("transcription connecting session=\(session) cause=panel"),
          !lines.contains(where: { $0.hasPrefix("hold began") })
    else {
        fail("\(label): opening the panel did not connect a session before any press, got \(sessionLines(after: logged))")
        return nil
    }
    print("  ok   \(label): opening the panel opened session \(session) before any press")
    return session
}

func silentHold() {
    guard capturePath != nil, scenarioPath != nil else { return }
    let label = "silent hold"
    useScenario("silent")
    defer { useScenario("ok") }
    _ = talk(for: 1.5)
    if wait(upTo: 3, until: { transcript() == "Didn't catch that" }) {
        print("  ok   \(label): the panel reads 'Didn't catch that'")
    } else {
        fail("\(label): the panel read '\(transcript())', expected 'Didn't catch that'")
    }
}

func mergedHolds() {
    guard capturePath != nil else { return }
    let label = "press again 0.3 s after the release"
    let logged = tail.count
    _ = talk(for: 3)
    wait(0.3)
    press()
    let during = samples(10)
    release()
    let releasedAt = Date()
    if during.allSatisfy({ !$0.isEmpty }) {
        print("  ok   \(label): the panel never cleared, \(Set(during.map { $0.prefix(16) }))")
    } else {
        fail("\(label): the panel went empty during the second hold: \(during)")
    }
    checkPanel(label, logged: logged, releasedAt: releasedAt, holds: 2)
}

func newUtterance() {
    guard capturePath != nil else { return }
    let label = "press again 1.5 s after the release"
    let logged = tail.count
    _ = talk(for: 3)
    wait(1.5)
    press()
    if wait(upTo: 0.3, until: { transcript().isEmpty }) {
        print("  ok   \(label): the press cleared the panel")
    } else {
        fail("\(label): 0.3 s after the press the panel still read '\(transcript())'")
    }
    let during = samples(10)
    release()
    let releasedAt = Date()
    // The first utterance is still waiting for its answer at the press, so it is delivered during the second hold.
    _ = wait(upTo: 2) { !deliveries(in: tail.lines(after: logged)).isEmpty }
    let lines = tail.lines(after: logged)
    guard let firstAt = lines.firstIndex(where: { $0.hasPrefix("transcription delivered ") }),
          let first = deliveries(in: [lines[firstAt]]).first
    else {
        fail("\(label): the first hold was never delivered")
        return
    }
    let turns = Set(first.text.split(separator: " ").filter { $0.hasPrefix("T") })
    let leaked = during.filter { sample in sample.split(separator: " ").contains { turns.contains($0) } }
    if leaked.isEmpty {
        print("  ok   \(label): no sample during the second hold showed the first one's turns \(turns.sorted())")
    } else {
        fail("\(label): the panel showed the first hold's turns during the second hold: \(leaked)")
    }
    guard let second = checkPanel(label, logged: logged + firstAt + 1, releasedAt: releasedAt) else { return }
    if second.utterance == first.utterance + 1, second.session == first.session {
        print("  ok   \(label): two utterances, \(first.utterance) then \(second.utterance), on session \(first.session)")
    } else {
        fail("\(label): expected utterance \(first.utterance + 1) on session \(first.session), got \(second.utterance) on \(second.session)")
    }
}

func serverClose(after session: Int) {
    guard capturePath != nil, scenarioPath != nil else { return }
    let label = "hold after a server close"
    let logged = tail.count
    useScenario("drop")
    let failed = wait(upTo: 3) { tail.lines(after: logged).contains { $0.hasPrefix("transcription failed session=\(session) stage=open reason=serverError code=1011") } }
    useScenario("ok")
    if failed {
        print("  ok   \(label): the fake's 1011 close failed session \(session) at stage=open")
    } else {
        fail("\(label): no 'transcription failed session=\(session) stage=open' line after the fake dropped it, got \(sessionLines(after: logged))")
    }
    press()
    if wait(upTo: 3, until: { transcript().hasPrefix("S\(session + 1) ") }) {
        print("  ok   \(label): words from session \(session + 1) showed while held: '\(transcript())'")
    } else {
        fail("\(label): no words from session \(session + 1) showed while held, the panel read '\(transcript())'")
    }
    release()
    _ = wait(upTo: 3) { !deliveries(in: tail.lines(after: logged)).isEmpty }
    let lines = tail.lines(after: logged)
    if lines.contains("transcription connecting session=\(session + 1) cause=press") {
        print("  ok   \(label): the press, not the failure, connected session \(session + 1)")
    } else {
        fail("\(label): expected the press to connect session \(session + 1), got \(sessionLines(after: logged))")
    }
}

func idleClose(session: Int) {
    guard capturePath != nil, let idleSeconds else { return }
    let label = "idle close"
    let logged = tail.count
    // The panel closes somewhere between the click and the poll that sees it gone, about 0.2 s apart.
    let clickedAt = Date()
    guard clickStatusItem(expecting: "0") else {
        fail("\(label): the panel did not close")
        return
    }
    let goneAt = Date()
    let closing = "transcription closing session=\(session) reason=idle"
    _ = wait(upTo: idleSeconds + 2) { tail.lines(after: logged).contains(closing) }
    let closedAt = tail.time(of: closing, after: logged)
    let afterClick = closedAt.map { $0.timeIntervalSince(clickedAt) } ?? -1
    let afterGone = closedAt.map { $0.timeIntervalSince(goneAt) } ?? -1
    let span = "\(String(format: "%.2f", afterGone)) to \(String(format: "%.2f", afterClick)) s after the panel closed"
    if afterClick >= idleSeconds, afterGone <= idleSeconds + 0.6 {
        print("  ok   \(label): session \(session) closed \(span)")
    } else {
        fail("\(label): '\(closing)' came \(span), expected \(idleSeconds) to \(idleSeconds + 0.6)")
    }
    if wait(upTo: 3, until: { tail.lines(after: logged).contains { $0.hasPrefix("transcription ended session=\(session) ") } }) {
        print("  ok   \(label): session \(session) read to its Termination")
    } else {
        fail("\(label): no 'transcription ended session=\(session)' line")
    }
    let reopened = tail.count
    guard clickStatusItem(expecting: "1") else {
        fail("\(label): the panel did not reopen")
        return
    }
    let opened = "transcription opened session=\(session + 1) token=reused"
    if wait(upTo: 3, until: { tail.lines(after: reopened).contains { $0.hasPrefix(opened) } }) {
        print("  ok   \(label): reopening the panel opened session \(session + 1) with the reused token before any press")
    } else {
        fail("\(label): no '\(opened)' line after reopening the panel, got \(sessionLines(after: reopened))")
    }
}

let warmed = warmFirst()
let holdsBegan = tail.count
hold("plain hold", .still)
checkScreenshots(logged: holdsBegan)
wait(0.5)
hold("hold dragged off the control", .draggedOff)
wait(0.5)
hold("hold while the speakers talk", .speakersTalking)
wait(0.5)
silentHold()
wait(0.5)
mergedHolds()
wait(0.5)
newUtterance()
if let warmed {
    let session = sessionLines(after: holdsBegan)
    if session.isEmpty {
        print("  ok   session \(warmed), opened with the panel, carried every hold")
    } else {
        fail("session \(warmed) did not carry every hold: \(session)")
    }
    serverClose(after: warmed)
    idleClose(session: warmed + 1)
}
finish()
