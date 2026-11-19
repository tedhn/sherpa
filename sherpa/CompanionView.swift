import SwiftUI

struct CompanionView: View {
    let companion: Companion
    let state: AppState
    /// The NSScreen.frame this overlay covers, in AppKit global coordinates.
    let screenFrame: CGRect

    var body: some View {
        let voice = state.voice
        let kind = look(for: voice).kind
        let moving = voice == .listening || voice == .processing
        // The level is read inside the timeline closure, as ContentView does, so each frame re-reads it.
        TimelineView(.animation(paused: !moving)) { context in
            CompanionGlyph(look: look(for: voice), time: context.date.timeIntervalSinceReferenceDate)
        }
        .animation(.easeInOut(duration: 0.15), value: kind)
        .opacity(companion.resting && voice == .idle ? 0 : 1)
        .position(Companion.local(companion.position, in: screenFrame))
        .onChange(of: voice) { companion.wake() }
        // The notched built-in display gives a full-screen window a top safe-area inset.
        // Without this, local y = 0 would sit below the notch, not at the screen's top edge.
        .ignoresSafeArea()
    }

    private func look(for voice: VoiceState) -> CompanionGlyph.Look {
        switch voice {
        case .idle, .responding: .arrow
        case .listening: .waveform(level: state.microphone.level.fraction)
        case .processing: .spinner
        }
    }
}
