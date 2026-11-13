import SwiftUI

struct CompanionView: View {
    let companion: Companion
    /// The NSScreen.frame this overlay covers, in AppKit global coordinates.
    let screenFrame: CGRect

    var body: some View {
        CompanionGlyph()
            .position(Companion.local(companion.position, in: screenFrame))
            // The notched built-in display gives a full-screen window a top safe-area inset.
            // Without this, local y = 0 would sit below the notch, not at the screen's top edge.
            .ignoresSafeArea()
    }
}

struct CompanionGlyph: View {
    /// The apex is drawn pointing up. Turn it to face back along the offset, at the hotspot:
    /// local offset is (35, 25) down-right, so the hotspot lies at atan2(-35, 25), about -54 degrees.
    static let heading = Angle.radians(atan2(-Companion.offset.dx, -Companion.offset.dy))
    static let tint = Color(red: 0.20, green: 0.48, blue: 1.0)

    var body: some View {
        Arrowhead(cornerRadius: 1.5)
            .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.66, blue: 1.0), Self.tint], startPoint: .top, endPoint: .bottom))
            .overlay(Arrowhead(cornerRadius: 1.5).stroke(.white, lineWidth: 1.5))
            .frame(width: 11, height: 24)
            .rotationEffect(Self.heading)
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
