import AVFoundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "state")
private nonisolated let inkLogger = Logger(subsystem: "my.rooftop.sherpa", category: "ink")

/// What Sherpa is doing for the person. Computed on read from the microphone and
/// the record on the panel, never stored.
nonisolated enum VoiceState: String, Sendable {
    /// Nothing is owed: no record, a final transcript with nothing to answer,
    /// a failed answer, or an answer whose voice has finished.
    case idle
    /// The microphone is capturing a hold.
    case listening
    /// Released with nothing to hear yet: the transcript is finishing, or
    /// Claude is being asked or is still writing.
    case processing
    /// The voice has the whole answer and is about to speak it, or is speaking it.
    case responding
}

enum MicrophonePhase {
    case ready
    case askingForAccess
    case listening(MicrophoneCapture)
    case failed(MicrophoneProblem)

    var level: BarFill {
        if case .listening(let capture) = self { capture.level } else { .empty }
    }
}

@MainActor
@Observable
final class AppState {
    private(set) var microphone: MicrophonePhase = .ready
    private(set) var transcription: Transcription?
    /// Strokes since the chord went down that no hold has claimed: the 0.3 s before a hold begins,
    /// or a chord that never becomes one.
    private(set) var loose = Ink()
    private let transcriber = Transcriber()
    @ObservationIgnored private var logged: VoiceState?

    init() {
        logVoiceChanges()
    }

    /// First match wins. Only a capture that started yields `.listening`, and
    /// that same press swaps the record and cancels the old answer, so no
    /// other microphone phase can end `.responding`.
    var voice: VoiceState {
        if case .listening = microphone { return .listening }
        guard let transcription else { return .idle }
        if transcription.speaking { return .responding }
        switch (transcription.shown, transcription.reply) {
        case (.hearing, nil), (_, .asking), (_, .answering): return .processing
        case (.final, nil), (_, .answered), (_, .failed): return .idle
        }
    }

    func panelOpened() {
        transcriber.warm()
    }

    func panelClosed() {
        transcriber.cool()
    }

    func quit() async {
        await transcriber.close()
    }

    func setHeld(_ held: Bool) {
        switch (held, microphone) {
        case (true, .ready), (true, .failed):
            beginHold()
        case (false, .listening):
            microphone = .ready
            transcriber.release()
        case (true, .listening), (true, .askingForAccess), (false, _):
            break
        }
    }

    /// While a hold captures, strokes go to its record; otherwise to `loose`. A hold's strokes are
    /// already on its record when the chord goes up, so `.released` and setHeld(false) give the
    /// same capture in either order.
    func draw(_ mark: Pen.Mark) {
        let holding: Transcription? = if case .listening = microphone { transcription } else { nil }
        switch (mark, holding) {
        case (.released, _):
            guard !loose.isEmpty else { return }
            inkLogger.notice("ink dropped strokes=\(self.loose.strokes.count)")
            loose = Ink()
        case (.began(let point), let record?):
            record.ink.begin(at: point)
        case (.moved(let point), let record?):
            record.ink.extend(to: point)
        case (.began(let point), nil):
            loose.begin(at: point)
        case (.moved(let point), nil):
            loose.extend(to: point)
        }
    }

    /// The record is replaced only by a press that reached the Transcriber, so a
    /// press whose microphone fails leaves the answer, and its voice, in place.
    private func beginHold() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            do throws(MicrophoneProblem) {
                let (capture, speech, recorded) = try MicrophoneCapture.start()
                microphone = .listening(capture)
                let record = transcriber.press(speech, recorded: recorded)
                claimLoose(into: record)
                transcription = record
            } catch {
                microphone = .failed(error)
            }
        case .notDetermined:
            microphone = .askingForAccess
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard case .askingForAccess = microphone else { return }
                microphone = granted ? .ready : .failed(.accessDenied)
            }
        case .denied:
            microphone = .failed(.accessDenied)
        case .restricted:
            microphone = .failed(.accessRestricted)
        @unknown default:
            microphone = .failed(.accessDenied)
        }
    }

    /// A merged press returns the same record, so its ink grows; a new utterance's record starts
    /// with this press's loose strokes.
    private func claimLoose(into record: Transcription) {
        guard !loose.isEmpty else { return }
        record.ink.append(loose)
        inkLogger.notice("ink claimed utterance=\(record.number) strokes=\(self.loose.strokes.count)")
        loose = Ink()
    }

    /// `onChange` fires once, at the first willSet, so the loop hops to the main
    /// actor, reads the settled value and re-arms. Changes within one main-actor
    /// turn coalesce, as they do on screen.
    private func logVoiceChanges() {
        // A strong capture inside the Task: `self?` there warns under the app's
        // flags (captured var in concurrently-executing code).
        let voice = withObservationTracking { self.voice } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.logVoiceChanges() }
        }
        guard voice != logged else { return }
        logged = voice
        logger.notice("""
            state voice=\(voice.rawValue, privacy: .public) \
            utterance=\(self.transcription.map { String($0.number) } ?? "none", privacy: .public)
            """)
    }
}
