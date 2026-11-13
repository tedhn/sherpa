import AVFoundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "state")

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

    /// The record is replaced only by a press that reached the Transcriber, so a
    /// press whose microphone fails leaves the answer, and its voice, in place.
    private func beginHold() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            do throws(MicrophoneProblem) {
                let (capture, speech, recorded) = try MicrophoneCapture.start()
                microphone = .listening(capture)
                transcription = transcriber.press(speech, recorded: recorded)
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
