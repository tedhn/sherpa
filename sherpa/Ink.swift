import CoreGraphics

/// One press of the left button under the chord, from its down to its up, in AppKit global points
/// (bottom-left of the primary display, y up). Never empty: the only initialiser takes the first
/// point. One point is a dot.
nonisolated struct Stroke: Equatable, Sendable {
    private(set) var points: [CGPoint]

    init(_ first: CGPoint, _ rest: [CGPoint] = []) {
        points = [first] + rest
    }

    mutating func extend(to point: CGPoint) {
        points.append(point)
    }
}

/// What the person drew, strokes in the order drawn. The look is fixed here once, for the overlay
/// and for the screenshot.
nonisolated struct Ink: Equatable, Sendable {
    static let width: CGFloat = 4
    static let red = CGColor(srgbRed: 1, green: 0.19, blue: 0.17, alpha: 1)

    private(set) var strokes: [Stroke]

    init(_ strokes: [Stroke] = []) {
        self.strokes = strokes
    }

    var isEmpty: Bool { strokes.isEmpty }

    mutating func begin(at point: CGPoint) {
        strokes.append(Stroke(point))
    }

    mutating func extend(to point: CGPoint) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].extend(to: point)
    }

    /// The other ink's strokes go last, so a stroke still being drawn keeps receiving `extend(to:)`.
    mutating func append(_ other: Ink) {
        strokes += other.strokes
    }

    /// A grid of `size` units with a top-left origin, laid over `frame` in AppKit global points:
    /// an overlay's SwiftUI space, or a screenshot's pixels.
    struct Plane: Equatable, Sendable {
        let frame: CGRect
        let size: CGSize

        func point(_ global: CGPoint) -> CGPoint {
            CGPoint(
                x: (global.x - frame.minX) * size.width / frame.width,
                y: (frame.maxY - global.y) * size.height / frame.height
            )
        }

        /// Never under 3 units, so a large display shrunk to 1280 px still gets a line Claude sees.
        var lineWidth: CGFloat {
            max(Ink.width * size.width / frame.width, 3)
        }
    }

    /// A one-point stroke is a circle as wide as the line, so stroking it paints a disk twice the
    /// line's width. A dot one line wide loses half its red to JPEG's 2 x 2 colour blocks.
    func path(in plane: Plane) -> CGPath {
        let path = CGMutablePath()
        for stroke in strokes {
            let points = stroke.points.map(plane.point)
            if points.count == 1 {
                let radius = plane.lineWidth / 2
                path.addEllipse(in: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: 2 * radius, height: 2 * radius))
            } else {
                path.addLines(between: points)
            }
        }
        return path
    }

    /// The strokes that can put a pixel inside `frame`. Their bounds grow by twice the width, which
    /// covers a dot's disk at the 3-unit floor down to 0.375 px per point.
    func touching(_ frame: CGRect) -> Ink {
        Ink(strokes.filter { stroke in
            let xs = stroke.points.map(\.x)
            let ys = stroke.points.map(\.y)
            let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            return bounds.insetBy(dx: -2 * Ink.width, dy: -2 * Ink.width).intersects(frame)
        })
    }

    /// The same image at the same size, with the strokes that touch `appKitFrame` drawn on it.
    /// Returns `image` itself when none do.
    func composited(onto image: CGImage, appKitFrame: CGRect) -> CGImage {
        let drawn = touching(appKitFrame)
        guard !drawn.isEmpty else { return image }
        let space = image.colorSpace.flatMap { $0.model == .rgb && $0.supportsOutput ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let plane = Plane(frame: appKitFrame, size: size)
        context.addPath(drawn.path(in: plane))
        context.setStrokeColor(Ink.red)
        context.setLineWidth(plane.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        return context.makeImage() ?? image
    }
}
