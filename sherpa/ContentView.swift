import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    // DragGesture rather than a button style: isPressed on a ButtonStyle goes
    // false when the pointer leaves the control, which would cut a speaker off
    // for wobbling. A gesture tracks until the mouse-up, and resets on cancel.
    @GestureState private var isPressed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Sherpa")
                .font(.largeTitle)
                .fontWeight(.bold)

            Image(systemName: "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(state.microphone.isListening ? Color.red : Color.accentColor, in: Circle())
                .scaleEffect(isPressed ? 0.94 : 1)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in pressed = true })
                .onChange(of: isPressed) { _, pressed in state.setHeld(pressed) }
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Hold to talk")

            TimelineView(.animation(paused: !state.microphone.isListening)) { _ in
                LevelBar(fill: state.microphone.level)
            }

            Text(caption)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(transcriptLine)
                .font(.body)
                .multilineTextAlignment(.center)
                .lineLimit(3, reservesSpace: true)
                .truncationMode(.head)

            if case .failed(.accessDenied) = state.microphone {
                Link("Open Privacy Settings", destination: Self.microphoneSettings)
            }
        }
        .padding(20)
        // A borderless window proposes no size to SwiftUI, so fittingSize
        // needs one axis pinned; width is it. The corners are drawn here, not
        // by the window — the window frame stays rectangular, and its
        // transparent corner pixels are what the panel's hasShadow traces.
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LevelBar: View {
    let fill: BarFill

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.quaternary)
            Rectangle().fill(.red).frame(width: 160 * fill.fraction)
        }
        .frame(width: 160, height: 6)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        // A custom element's string value reads as `missing value` in System
        // Events. A progress indicator reads as a number the harness compares.
        .accessibilityRepresentation {
            ProgressView(value: fill.fraction)
                .accessibilityLabel("Input level")
        }
    }
}

private extension ContentView {
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    var caption: String {
        switch state.microphone {
        case .ready: "Hold to talk"
        case .askingForAccess: "Allow microphone access to talk"
        case .listening: "Listening…"
        case .failed(.accessDenied): "Microphone access is off"
        case .failed(.accessRestricted): "Microphone access is restricted"
        case .failed(.noInputDevice): "No microphone found"
        case .failed(.engineFailed): "Couldn't start the microphone"
        }
    }

    var transcriptLine: String {
        guard let transcription = state.transcription else { return "" }
        switch transcription.shown {
        case .hearing(let words): return words.isEmpty && !state.microphone.isListening ? "…" : words
        case .final(.heard(let sentence)): return sentence
        case .final(.silence): return "Didn't catch that"
        case .final(.failed(.noAPIKey)): return "No AssemblyAI key is set"
        case .final(.failed(.tokenRefused)): return "AssemblyAI refused the key"
        case .final(.failed(.serverError)): return "AssemblyAI closed the session"
        case .final(.failed(.timedOut)): return "AssemblyAI didn't answer"
        case .final(.failed(.transport)): return "Couldn't reach AssemblyAI"
        }
    }
}

#Preview {
    ContentView(state: AppState())
}
