import AVFoundation
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

// The only object the audio thread touches. Everything else here is main
// actor, and the tap is passed as the method reference `tally.receive` rather
// than a closure literal: a literal written inside a main-actor type compiles
// with no diagnostic even when it mutates main-actor state from the audio
// thread, and a method on a nonisolated class warns.
nonisolated final class FrameTally: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: FrameCounts())

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        let now = ContinuousClock.now
        let total = counts.withLock { counts in
            counts.buffers += 1
            counts.frames += frames
            if counts.firstBuffer == nil { counts.firstBuffer = now }
            return counts
        }
        logger.debug("buffer n=\(total.buffers) frames=\(frames) total=\(total.frames)")
    }

    var snapshot: FrameCounts { counts.withLock { $0 } }
}

final class MicrophoneCapture {
    private let engine: AVAudioEngine
    private let tally: FrameTally
    private let rate: Double
    private let started: ContinuousClock.Instant

    static func start() throws(MicrophoneProblem) -> MicrophoneCapture {
        let started = ContinuousClock.now
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // installTap raises an Objective-C exception on a 0-channel format,
        // which Swift cannot catch.
        guard format.channelCount > 0, format.sampleRate > 0 else {
            logger.notice("hold failed reason=noInputDevice")
            throw .noInputDevice
        }
        let tally = FrameTally()
        // The tap delivers 100 to 400 ms per buffer whatever is asked, so ask
        // for the shortest.
        let tenthOfASecond = AVAudioFrameCount(format.sampleRate / 10)
        input.installTap(onBus: 0, bufferSize: tenthOfASecond, format: format, block: tally.receive)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            logger.error("hold failed reason=engineFailed error=\(error.localizedDescription, privacy: .public)")
            throw .engineFailed
        }
        logger.notice("hold began rate=\(format.sampleRate, format: .fixed(precision: 0)) channels=\(format.channelCount)")
        return MicrophoneCapture(engine: engine, tally: tally, rate: format.sampleRate, started: started)
    }

    private init(engine: AVAudioEngine, tally: FrameTally, rate: Double, started: ContinuousClock.Instant) {
        self.engine = engine
        self.tally = tally
        self.rate = rate
        self.started = started
    }

    isolated deinit {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let counts = tally.snapshot
        let seconds = started.duration(to: .now) / .seconds(1)
        let firstBuffer = counts.firstBuffer.map { String(format: "%.3f", started.duration(to: $0) / .seconds(1)) } ?? "none"
        logger.notice("""
            hold ended frames=\(counts.frames) buffers=\(counts.buffers) \
            seconds=\(seconds, format: .fixed(precision: 3)) \
            rate=\(self.rate, format: .fixed(precision: 0)) \
            firstBuffer=\(firstBuffer, privacy: .public)
            """)
    }
}
