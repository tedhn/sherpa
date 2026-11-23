import Accelerate
import AppKit
import AVFoundation
import CoreAudio
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "microphone")

enum MicrophoneProblem: Error, Equatable {
    case accessDenied, accessRestricted, noInputDevice, engineFailed
}

nonisolated struct FrameCounts: Sendable {
    var buffers = 0
    var frames = 0
    var firstBuffer: ContinuousClock.Instant?
}

// The tap is passed as the method reference `receiver.receive` rather than a
// closure literal: a literal written inside a main-actor type compiles with no
// diagnostic even when it mutates main-actor state from the audio thread, and
// a method on a nonisolated class warns.
nonisolated final class TapReceiver: Sendable {
    private struct Recording {
        let converter: SpeechConverter
        let speech: SpeechStream.Continuation
        var pcm = Data()

        mutating func record(_ pcm: Data) {
            self.pcm.append(pcm)
            if !pcm.isEmpty { speech.yield(pcm) }
        }
    }

    private let counts = OSAllocatedUnfairLock(initialState: FrameCounts())
    private let meter = OSAllocatedUnfairLock(initialState: LevelMeter())
    private let recording: OSAllocatedUnfairLock<Recording>

    init(converter: SpeechConverter, speech: SpeechStream.Continuation) {
        recording = OSAllocatedUnfairLock(uncheckedState: Recording(converter: converter, speech: speech))
    }

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        let dBFS = buffer.loudestChannelRMSDBFS
        let now = ContinuousClock.now
        let total = counts.withLock { counts in
            counts.buffers += 1
            counts.frames += frames
            if counts.firstBuffer == nil { counts.firstBuffer = now }
            return counts
        }
        meter.withLock { $0.hear(dBFS: dBFS, at: now) }
        recording.withLockUnchecked { recording in
            recording.record(recording.converter.convert(buffer))
        }
        logger.debug("buffer n=\(total.buffers) frames=\(frames) total=\(total.frames) dBFS=\(dBFS, format: .fixed(precision: 1))")
    }

    var snapshot: FrameCounts { counts.withLock { $0 } }

    var level: BarFill {
        meter.withLock { $0 }.fill(at: .now)
    }

    var recorded: Data { recording.withLockUnchecked { $0.pcm } }

    func finishRecording() -> Data {
        recording.withLockUnchecked { recording in
            recording.record(recording.converter.finish())
            recording.speech.finish()
            return recording.pcm
        }
    }
}

private extension AVAudioPCMBuffer {
    nonisolated var loudestChannelRMSDBFS: Float {
        var loudest: Float = 0
        if let channels = floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                let samples = UnsafeBufferPointer(start: channels[channel], count: Int(frameLength))
                loudest = max(loudest, vDSP.rootMeanSquare(samples))
            }
        }
        return 20 * log10(max(loudest, 1e-6))
    }
}

// One tap lives as long as the input engine, so it delivers to whichever hold
// is attached and drops buffers between holds.
nonisolated final class TapRouter: Sendable {
    private let attached = OSAllocatedUnfairLock<TapReceiver?>(initialState: nil)

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        attached.withLock { $0 }?.receive(buffer, at: time)
    }

    func attach(_ receiver: TapReceiver) {
        attached.withLock { $0 = receiver }
    }

    func detach(_ receiver: TapReceiver) {
        attached.withLock { if $0 === receiver { $0 = nil } }
    }

    func detachAll() {
        attached.withLock { $0 = nil }
    }
}

/// Keeps one input engine open while Sherpa runs, so a press never starts or
/// stops CoreAudio IO. Opening a Bluetooth headset's microphone switches it from
/// A2DP to HFP and pauses every app's audio while it does. A failed open leaves
/// `device` nil, so `wanted` records that the input should still be open.
final class Microphone {
    private struct Open {
        let engine: AVAudioEngine
        let format: AVAudioFormat
        let observer: NSObjectProtocol
    }

    private let router = TapRouter()
    private var device: Open?
    private var wanted = false
    private var retry: Task<Void, Never>?

    init() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.reopen(reason: "device")
        }
        // An open input holds a PreventUserIdleSystemSleep assertion, so the
        // Mac would never idle-sleep while Sherpa runs.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close(reason: "sleep") }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openIfAllowed(reason: "wake") }
        }
    }

    @discardableResult
    func open(reason: String) throws(MicrophoneProblem) -> AVAudioFormat {
        if let device { return device.format }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // installTap raises an Objective-C exception on a 0-channel format,
        // which Swift cannot catch.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            logger.notice("microphone open failed reason=\(reason, privacy: .public) problem=noInputDevice")
            throw .noInputDevice
        }
        // The tap delivers 100 to 400 ms per buffer whatever is asked, so ask
        // for the shortest. It is the method reference `router.receive` for the
        // reason given on TapReceiver.
        let tenthOfASecond = AVAudioFrameCount(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: tenthOfASecond, format: format, block: router.receive)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            logger.error("microphone open failed reason=\(reason, privacy: .public) problem=engineFailed error=\(error.localizedDescription, privacy: .public)")
            throw .engineFailed
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reopen(reason: "configuration") }
        }
        device = Open(engine: engine, format: format, observer: observer)
        logger.notice("microphone opened reason=\(reason, privacy: .public) rate=\(format.sampleRate, format: .fixed(precision: 0)) channels=\(format.channelCount)")
        return format
    }

    func openIfAllowed(reason: String) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        wanted = true
        openWanted(reason: reason)
    }

    func close(reason: String) {
        wanted = false
        retry?.cancel()
        tearDown(reason: reason)
    }

    private func reopen(reason: String) {
        guard wanted || device != nil else { return }
        tearDown(reason: reason)
        openWanted(reason: reason)
    }

    private func openWanted(reason: String) {
        retry?.cancel()
        if (try? open(reason: reason)) != nil { return }
        retry = Task { [weak self] in
            for _ in 1...5 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if (try? open(reason: "retry")) != nil { return }
            }
        }
    }

    private func tearDown(reason: String) {
        guard let device else { return }
        self.device = nil
        router.detachAll()
        device.engine.inputNode.removeTap(onBus: 0)
        device.engine.stop()
        NotificationCenter.default.removeObserver(device.observer)
        logger.notice("microphone closed reason=\(reason, privacy: .public)")
    }

    func capture() throws(MicrophoneProblem) -> (capture: MicrophoneCapture, speech: SpeechStream, recorded: @Sendable () -> Data) {
        #if DEBUG
        // The harness cannot make a working Mac's microphone fail, so it writes
        // engineFailed into this file between presses. Read on each press.
        if let path = UserDefaults.standard.string(forKey: "MicrophoneScenarioFile"),
           (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "engineFailed" {
            logger.notice("hold failed reason=engineFailed scenario=file")
            throw .engineFailed
        }
        #endif
        let started = ContinuousClock.now
        let format: AVAudioFormat
        do throws(MicrophoneProblem) {
            format = try open(reason: "press")
        } catch {
            logger.notice("hold failed reason=\(String(describing: error), privacy: .public)")
            throw error
        }
        guard let converter = SpeechConverter(from: format) else {
            logger.notice("hold failed reason=converter")
            throw .engineFailed
        }
        let (speech, continuation) = SpeechStream.makeStream(bufferingPolicy: .unbounded)
        let receiver = TapReceiver(converter: converter, speech: continuation)
        router.attach(receiver)
        logger.notice("hold began rate=\(format.sampleRate, format: .fixed(precision: 0)) channels=\(format.channelCount)")
        let capture = MicrophoneCapture(router: router, receiver: receiver, rate: format.sampleRate, started: started)
        return (capture, speech, { receiver.recorded })
    }
}

final class MicrophoneCapture {
    private static let wavURL = URL.cachesDirectory.appending(components: "my.rooftop.sherpa", "last-hold.wav")

    private let router: TapRouter
    private let receiver: TapReceiver
    private let rate: Double
    private let started: ContinuousClock.Instant

    fileprivate init(router: TapRouter, receiver: TapReceiver, rate: Double, started: ContinuousClock.Instant) {
        self.router = router
        self.receiver = receiver
        self.rate = rate
        self.started = started
    }

    var level: BarFill { receiver.level }

    isolated deinit {
        router.detach(receiver)
        let counts = receiver.snapshot
        let seconds = started.duration(to: .now) / .seconds(1)
        let firstBuffer = counts.firstBuffer.map { String(format: "%.3f", started.duration(to: $0) / .seconds(1)) } ?? "none"
        logger.notice("""
            hold ended frames=\(counts.frames) buffers=\(counts.buffers) \
            seconds=\(seconds, format: .fixed(precision: 3)) \
            rate=\(self.rate, format: .fixed(precision: 0)) \
            firstBuffer=\(firstBuffer, privacy: .public)
            """)
        let wav = WAV.file(receiver.finishRecording())
        do {
            try FileManager.default.createDirectory(at: Self.wavURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wav.write(to: Self.wavURL)
            logger.notice("wav saved bytes=\(wav.count) path=\(Self.wavURL.path, privacy: .public)")
        } catch {
            logger.error("wav failed error=\(error.localizedDescription, privacy: .public)")
        }
    }
}
