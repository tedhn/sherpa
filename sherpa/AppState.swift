import AVFoundation
import Combine

enum MicrophonePhase {
    case ready
    case askingForAccess
    case listening(MicrophoneCapture)
    case failed(MicrophoneProblem)

    var isListening: Bool {
        if case .listening = self { true } else { false }
    }

    var level: BarFill {
        if case .listening(let capture) = self { capture.level } else { .empty }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var microphone: MicrophonePhase = .ready
    @Published private(set) var transcription: Transcription?
    private let transcriber = Transcriber()

    func setHeld(_ held: Bool) {
        switch (held, microphone) {
        case (true, .ready), (true, .failed):
            beginHold()
        case (false, .listening):
            microphone = .ready
        case (true, .listening), (true, .askingForAccess), (false, _):
            break
        }
    }

    private func beginHold() {
        transcription = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            do throws(MicrophoneProblem) {
                let (capture, speech) = try MicrophoneCapture.start()
                microphone = .listening(capture)
                transcription = transcriber.transcribe(speech)
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
}
