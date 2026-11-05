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

            Text(caption)
                .font(.title3)
                .foregroundStyle(.secondary)

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
}

#Preview {
    ContentView(state: AppState())
}
