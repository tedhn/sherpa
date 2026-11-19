import SwiftUI

struct CompanionGlyph: View {
    enum Look: Equatable {
        case arrow(heading: Angle)
        case waveform(level: Double)
        case spinner

        /// The look without its level, so a cross-fade runs between looks and not on every level change.
        var kind: Int {
            switch self {
            case .arrow: 0
            case .waveform: 1
            case .spinner: 2
            }
        }
    }

    static let tint = Color(red: 0.20, green: 0.48, blue: 1.0)
    private static let pale = Color(red: 0.42, green: 0.66, blue: 1.0)
    private static let barProfile: [Double] = [0.55, 0.85, 1.0, 0.85, 0.55]

    let look: Look
    /// Seconds on any clock; drives the waveform's wobble and the spinner's turn.
    let time: Double

    var body: some View {
        switch look {
        case .arrow(let heading): arrow(heading: heading)
        case .waveform(let level): waveform(level: level)
        case .spinner: spinner
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(colors: [Self.pale, Self.tint], startPoint: .top, endPoint: .bottom)
    }

    private func arrow(heading: Angle) -> some View {
        Arrowhead(cornerRadius: 1.5)
            .fill(gradient)
            .overlay(Arrowhead(cornerRadius: 1.5).stroke(.white, lineWidth: 1.5))
            .frame(width: 11, height: 24)
            .rotationEffect(heading)
            .shadow(color: Self.tint.opacity(0.7), radius: 6)
    }

    private func waveform(level: Double) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<5, id: \.self) { bar in
                let wobble = 0.8 + 0.2 * sin(time * 9 + Double(bar) * 1.3)
                Capsule()
                    .fill(gradient)
                    .overlay(Capsule().stroke(.white, lineWidth: 1))
                    .frame(width: 3.5, height: 5 + 15 * level * Self.barProfile[bar] * wobble)
            }
        }
        .frame(width: 26, height: 24)
        .shadow(color: Self.tint.opacity(0.7), radius: 6)
    }

    private var spinner: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.7).stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Circle().trim(from: 0, to: 0.7).stroke(gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .frame(width: 15, height: 15)
        .rotationEffect(.degrees(time * 360 / 0.9))
        .shadow(color: Self.tint.opacity(0.7), radius: 6)
    }
}

/// A narrow triangle, apex up, three quarters of the rect's height tall. Narrow so the apex reads
/// as the tip once turned toward the hotspot. The base sits low enough that the centroid is the
/// rect's centre, so rotating about the centre keeps the glyph's centre at `Companion.position`,
/// and the harness can find the position as the centroid of the glyph's opaque pixels.
private struct Arrowhead: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let height = rect.height * 3 / 4
        let vertices = [
            CGPoint(x: rect.midX, y: rect.midY - height * 2 / 3),
            CGPoint(x: rect.maxX, y: rect.midY + height / 3),
            CGPoint(x: rect.minX, y: rect.midY + height / 3),
        ]
        var path = Path()
        path.move(to: CGPoint(x: (vertices[2].x + vertices[0].x) / 2, y: (vertices[2].y + vertices[0].y) / 2))
        for index in vertices.indices {
            path.addArc(tangent1End: vertices[index], tangent2End: vertices[(index + 1) % 3], radius: cornerRadius)
        }
        path.closeSubpath()
        return path
    }
}

struct CompanionBubble: View {
    let bubble: Bubble
    let shown: Int

    var body: some View {
        Text(bubble.label.prefix(shown))
            .font(Font(Bubble.font as CTFont))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, Bubble.padding.width)
            .frame(height: bubble.frame.height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(CompanionGlyph.tint)
                    .shadow(color: CompanionGlyph.tint.opacity(0.5), radius: 6)
            )
            .frame(width: bubble.frame.width, height: bubble.frame.height, alignment: bubble.side == .right ? .leading : .trailing)
    }
}

struct TypingBubble: View {
    let bubble: Bubble

    var body: some View {
        // SwiftUI's explicit schedule never fires its final date, so the last reveal must not be last.
        TimelineView(.explicit((0..<bubble.label.count).map { bubble.appeared + Bubble.reveal($0) / .seconds(1) } + [.distantFuture])) { context in
            let elapsed = (max(context.date, .now).timeIntervalSince(bubble.appeared) * 1000).rounded()
            CompanionBubble(bubble: bubble, shown: bubble.revealed(after: .milliseconds(elapsed)))
        }
    }
}

struct BubblePop: Transition {
    let anchor: UnitPoint

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase == .willAppear ? 0.5 : 1, anchor: anchor)
            .shadow(color: CompanionGlyph.tint.opacity(phase == .willAppear ? 1 : 0), radius: phase == .willAppear ? 22 : 6)
            .opacity(phase == .didDisappear ? 0 : 1)
    }
}

struct InkLayer: View {
    let ink: Ink
    let screenFrame: CGRect

    static let fade = AnyTransition.asymmetric(
        insertion: .identity,
        removal: AnyTransition.opacity.animation(.easeOut(duration: 0.3))
    )

    var body: some View {
        let plane = Ink.Plane(frame: screenFrame, size: screenFrame.size)
        InkShape(ink: ink, plane: plane)
            .stroke(Color(cgColor: Ink.red), style: StrokeStyle(lineWidth: plane.lineWidth, lineCap: .round, lineJoin: .round))
    }
}

private struct InkShape: Shape {
    let ink: Ink
    let plane: Ink.Plane

    func path(in rect: CGRect) -> Path {
        Path(ink.path(in: plane))
    }
}
