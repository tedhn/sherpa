import AppKit
import CoreAudio

let arguments = Array(CommandLine.arguments.dropFirst())
guard let pid = arguments.first.flatMap(Int32.init) else {
    print("  FAIL no process id given")
    exit(1)
}

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
            "--predicate", "subsystem == \"my.rooftop.sherpa\" AND category == \"microphone\"",
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

    func loudest(after count: Int) -> Double? {
        lock.withLock {
            messages.dropFirst(count)
                .filter { $0.hasPrefix("buffer ") }
                .compactMap { fields(of: $0)["dBFS"] }
                .max()
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
    checkMeter(label, kind, samples: samples, released: released, loudest: tail.loudest(after: logged))
}

hold("plain hold", .still)
wait(0.5)
hold("hold dragged off the control", .draggedOff)
wait(0.5)
hold("hold while the speakers talk", .speakersTalking)
finish()
