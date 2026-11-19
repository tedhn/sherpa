import SwiftUI

struct CompanionView: View {
    let companion: Companion
    let state: AppState
    /// The NSScreen.frame this overlay covers, in AppKit global coordinates.
    let screenFrame: CGRect

    var body: some View {
        let voice = state.voice
        let heading = companion.heading
        let kind = look(for: voice, heading: heading).kind
        let moving = voice == .listening || voice == .processing
        // The level is read inside the timeline closure, as ContentView does, so each frame re-reads it.
        TimelineView(.animation(paused: !moving)) { context in
            CompanionGlyph(look: look(for: voice, heading: heading), time: context.date.timeIntervalSinceReferenceDate)
        }
        .animation(.easeInOut(duration: 0.15), value: kind)
        .opacity(companion.resting && voice == .idle ? 0 : 1)
        .position(Companion.local(companion.position, in: screenFrame))
        .background { UserInk(state: state, screenFrame: screenFrame) }
        .overlay {
            if let ring = companion.ring {
                DrawingRing(around: CGRect(origin: Companion.local(CGPoint(x: ring.minX, y: ring.maxY), in: screenFrame), size: ring.size))
                    .transition(DrawingRing.fade)
            }
        }
        .overlay {
            if let bubble = companion.bubble {
                let centre = Companion.local(CGPoint(x: bubble.frame.midX, y: bubble.frame.midY), in: screenFrame)
                let edge = centre.x + (bubble.side == .right ? -1 : 1) * bubble.frame.width / 2
                // SwiftUI applies the transition to the whole branch, which .position stretches over
                // the overlay, so the pop's anchor is the glyph-side edge in overlay units.
                TypingBubble(bubble: bubble)
                    .position(centre)
                    .transition(BubblePop(anchor: UnitPoint(x: edge / screenFrame.width, y: centre.y / screenFrame.height)))
                    .id(bubble.appeared)
            }
        }
        .onChange(of: voice) { companion.wake() }
        .onChange(of: voice == .responding ? state.transcription?.pointing : nil) { _, callout in
            companion.point(at: callout)
        }
        // The notched built-in display gives a full-screen window a top safe-area inset.
        // Without this, local y = 0 would sit below the notch, not at the screen's top edge.
        .ignoresSafeArea()
    }

    private func look(for voice: VoiceState, heading: Angle) -> CompanionGlyph.Look {
        switch voice {
        case .idle, .responding: .arrow(heading: heading)
        case .listening: .waveform(level: state.microphone.level.fraction)
        case .processing: .spinner
        }
    }
}

struct UserInk: View {
    let state: AppState
    let screenFrame: CGRect

    /// Two layers split at the current question's mark, so when its answer spends the strokes it
    /// was asked with, only those fade and the strokes drawn since stay put.
    var body: some View {
        let shown = state.shownInk.strokes
        let since = state.transcription?.sentThrough.map { state.sheet.ink(after: $0).strokes } ?? shown
        let asked = Ink(Array(shown.dropLast(since.count)))
        ZStack {
            if !asked.isEmpty {
                InkLayer(ink: asked, screenFrame: screenFrame)
                    .id(state.transcription?.number)
                    .transition(InkLayer.fade)
            }
            if !since.isEmpty {
                InkLayer(ink: Ink(since), screenFrame: screenFrame)
                    .transition(InkLayer.fade)
            }
        }
    }
}
