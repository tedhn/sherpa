import CoreGraphics
import Foundation

nonisolated struct HandMark: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case ring(CGRect)
        case underline(CGRect)
        case arrow(from: CGRect, to: CGRect)
    }

    struct Nib: Equatable, Sendable {
        let point: CGPoint
        let width: CGFloat
        let timeShare: Double
    }

    /// The pen lifts between strokes.
    let strokes: [[Nib]]
    let duration: Double

    private typealias Stroke = [(point: CGPoint, width: CGFloat)]

    private static let baseWidth = 3.4
    private static let turns = 1.12
    private static let exponent = 2.6
    private static let leastMargin = 4.0
    private static let cornerClearance = 3.0
    private static let pause = 0.07
    private static let arrowPush = 6.0
    private static let shortestShaft = 16.0
    private static let farShaft = 28.0

    init(_ shape: Shape) {
        let drawn: [Stroke]
        switch shape {
        case .ring(let box):
            drawn = [Self.ring(around: box)]
            duration = min(0.38 + 0.14 * log2(max((box.width + box.height) / 60, 1)), 0.75)
        case .underline(let box):
            drawn = [Self.underline(under: box)]
            duration = 0.3 + 0.2 * min(box.width / 400, 1)
        case .arrow(let from, let to):
            drawn = Self.arrow(from: from, to: to)
            let length = Self.length(of: drawn[0].map(\.point))
            duration = 0.45 + 0.3 * min(length / 500, 1)
        }
        let lengths = drawn.map { Self.length(of: $0.map(\.point)) }
        let pauses = Self.pause * Double(drawn.count - 1)
        var start = 0.0
        strokes = drawn.indices.map { k in
            let share = (1 - pauses) * lengths[k] / lengths.reduce(0, +)
            let times = Self.twoThirdsPowerLawTimeShares(of: drawn[k].map(\.point))
            defer { start += share + Self.pause }
            return drawn[k].indices.map { Nib(point: drawn[k][$0].point, width: drawn[k][$0].width, timeShare: start + share * times[$0]) }
        }
    }

    private static func ring(around box: CGRect) -> Stroke {
        var rng = SplitMix64(seeded: [box.minX, box.minY, box.width, box.height])
        let spiral = rng.range(0.03, 0.07)
        let tilt = rng.range(-2.5, 2.5) * min(1, 120 / max(box.width, box.height)) * .pi / 180
        let start = rng.range(1.55, 1.8) * .pi
        let wobbles = (2...4).map { k in (frequency: Double(k), amplitude: rng.range(0.006, 0.02), phase: rng.range(0, 2 * .pi)) }
        let shift = CGPoint(x: rng.range(-0.02, 0.02) * box.width, y: rng.range(-0.04, 0.04) * box.height)
        let widthPhase = rng.range(0, 2 * .pi)

        func oval(margin: Double, count: Int) -> [CGPoint] {
            let a = box.width / 2 + margin, b = box.height / 2 + margin
            return (0...count).map { i in
                let t = Double(i) / Double(count)
                let theta = start - 2 * .pi * turns * t
                var scale = 1 + spiral * (t - 0.5) * 2 / turns
                for wobble in wobbles { scale += wobble.amplitude * sin(wobble.frequency * theta + wobble.phase) }
                let c = cos(theta), s = sin(theta)
                let x = a * scale * (c < 0 ? -1 : 1) * pow(abs(c), 2 / exponent)
                let y = b * scale * (s < 0 ? -1 : 1) * pow(abs(s), 2 / exponent)
                return CGPoint(x: box.midX + shift.x + x * cos(tilt) - y * sin(tilt), y: box.midY + shift.y + x * sin(tilt) + y * cos(tilt))
            }
        }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        func clearsBox(_ margin: Double) -> Bool {
            let points = oval(margin: margin, count: 240)
            let firstTurn = Array(points.prefix(Int(240 / turns) + 1))
            return corners.allSatisfy { encloses(firstTurn, $0) && distance(from: $0, toPolyline: points) >= cornerClearance }
        }
        var low = 0.0, high = 4 * max(box.width, box.height) + 20
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if clearsBox(middle) { high = middle } else { low = middle }
        }
        let margin = max(high, leastMargin)
        let length = turns * 2 * .pi * sqrt(((box.width / 2 + margin) * (box.width / 2 + margin) + (box.height / 2 + margin) * (box.height / 2 + margin)) / 2)
        let count = max(240, Int(length / 2))
        let points = oval(margin: margin, count: count)
        return points.indices.map { i in
            let t = Double(i) / Double(count)
            let taperIn = 0.35 + 0.65 * smoothstep(0, 0.1, t)
            let taperOut = 1 - 0.75 * smoothstep(1 - 0.22 / turns, 1, t)
            let flutter = 1 + 0.12 * sin(2 * .pi * 1.3 * t + widthPhase)
            return (points[i], baseWidth * taperIn * taperOut * flutter)
        }
    }

    private static func underline(under box: CGRect) -> Stroke {
        var rng = SplitMix64(seeded: [box.minX, box.minY, box.width, box.height])
        let y = box.maxY + 5.5 + rng.range(-0.5, 0.5)
        let start = CGPoint(x: box.minX - rng.range(2, 6), y: y + rng.range(-0.3, 0.8))
        let end = CGPoint(x: box.maxX + rng.range(3, 9), y: y - rng.range(1, 3))
        let sag = rng.range(0.8, 2.0), phase = rng.range(0, 2 * .pi)
        let count = max(Int(hypot(end.x - start.x, end.y - start.y) / 2), 40)
        return (0...count).map { i in
            let t = Double(i) / Double(count)
            let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t + sag * sin(.pi * t) + 0.4 * sin(2 * .pi * 2.3 * t + phase))
            return (point, 3.2 * (0.45 + 0.55 * smoothstep(0, 0.06, t)) * (1 - 0.7 * smoothstep(0.8, 1, t)))
        }
    }

    private static func arrow(from source: CGRect, to target: CGRect) -> [Stroke] {
        var rng = SplitMix64(seeded: [source.minX, source.minY, source.width, source.height, target.minX, target.minY, target.width, target.height])
        let (a, b) = nearestPoints(source, target)
        let gap = hypot(b.x - a.x, b.y - a.y)
        let start: CGPoint, tip: CGPoint
        if gap >= 2 * arrowPush + shortestShaft {
            let dx = (b.x - a.x) / gap, dy = (b.y - a.y) / gap
            start = CGPoint(x: a.x + dx * arrowPush, y: a.y + dy * arrowPush)
            tip = CGPoint(x: b.x - dx * arrowPush, y: b.y - dy * arrowPush)
        } else {
            // Boxes that overlap or nearly touch leave no room between them, so the arrow comes in from the far side of the target along the line between centres.
            let cx = target.midX - source.midX, cy = target.midY - source.midY
            let norm = hypot(cx, cy)
            let (dx, dy) = norm > 1e-3 ? (cx / norm, cy / norm) : (1, 0)
            let reach = min(abs(dx) > 1e-6 ? target.width / 2 / abs(dx) : .infinity, abs(dy) > 1e-6 ? target.height / 2 / abs(dy) : .infinity) + arrowPush
            tip = CGPoint(x: target.midX + dx * reach, y: target.midY + dy * reach)
            start = CGPoint(x: tip.x + dx * farShaft, y: tip.y + dy * farShaft)
        }
        let length = hypot(tip.x - start.x, tip.y - start.y)
        let bend = rng.range(0.08, 0.16) * (rng.range(0, 1) < 0.5 ? -1 : 1) * length
        let mid = CGPoint(x: (start.x + tip.x) / 2 - (tip.y - start.y) / length * bend, y: (start.y + tip.y) / 2 + (tip.x - start.x) / length * bend)
        let count = max(Int(length / 2), 40)
        let shaft = (0...count).map { i -> CGPoint in
            let t = Double(i) / Double(count), u = 1 - t
            return CGPoint(x: u * u * start.x + 2 * u * t * mid.x + t * t * tip.x, y: u * u * start.y + 2 * u * t * mid.y + t * t * tip.y)
        }
        let heading = atan2(tip.y - shaft[count - 3].y, tip.x - shaft[count - 3].x)
        let barb = min(15, 0.28 * length), spread = rng.range(24, 32) * .pi / 180, skew = rng.range(-4, 4) * .pi / 180
        let left = CGPoint(x: tip.x - barb * cos(heading - spread + skew), y: tip.y - barb * sin(heading - spread + skew))
        let right = CGPoint(x: tip.x - barb * 0.9 * cos(heading + spread + skew), y: tip.y - barb * 0.9 * sin(heading + spread + skew))
        let headCount = 20
        let head = (0...headCount).map { i -> CGPoint in
            let t = Double(i) / Double(headCount)
            let (from, to, along) = t < 0.5 ? (left, tip, t * 2) : (tip, right, (t - 0.5) * 2)
            return CGPoint(x: from.x + (to.x - from.x) * along, y: from.y + (to.y - from.y) * along)
        }
        return [
            shaft.indices.map { i in
                let t = Double(i) / Double(count)
                return (shaft[i], 3.2 * (0.4 + 0.6 * smoothstep(0, 0.1, t)) * (1 - 0.25 * smoothstep(0.85, 1, t)))
            },
            head.indices.map { i in
                let t = Double(i) / Double(headCount)
                return (head[i], 3.0 * (0.5 + 0.5 * smoothstep(0, 0.2, t)) * (1 - 0.6 * smoothstep(0.75, 1, t)))
            },
        ]
    }

    private static func nearestPoints(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint) {
        func facing(_ aLow: Double, _ aHigh: Double, _ bLow: Double, _ bHigh: Double) -> (Double, Double) {
            if aHigh < bLow { return (aHigh, bLow) }
            if bHigh < aLow { return (aLow, bHigh) }
            let middle = (max(aLow, bLow) + min(aHigh, bHigh)) / 2
            return (middle, middle)
        }
        let x = facing(a.minX, a.maxX, b.minX, b.maxX), y = facing(a.minY, a.maxY, b.minY, b.maxY)
        return (CGPoint(x: x.0, y: y.0), CGPoint(x: x.1, y: y.1))
    }

    private static func length(of points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    func path(drawnTo share: Double) -> CGPath {
        let path = CGMutablePath()
        guard let first = strokes.first?.first else { return path }
        path.addPath(Self.capsule(from: first.point, to: first.point, width: first.width))
        for stroke in strokes {
            for (a, b) in zip(stroke, stroke.dropFirst()) where b.timeShare <= share {
                path.addPath(Self.capsule(from: a.point, to: b.point, width: (a.width + b.width) / 2))
            }
        }
        return path
    }

    private static func capsule(from a: CGPoint, to b: CGPoint, width: CGFloat) -> CGPath {
        let length = hypot(b.x - a.x, b.y - a.y)
        let rect = CGRect(x: -width / 2, y: -width / 2, width: length + width, height: width)
        let place = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: atan2(b.y - a.y, b.x - a.x))
        return CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: [place])
    }

    private static func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func twoThirdsPowerLawTimeShares(of points: [CGPoint]) -> [Double] {
        var times = [0.0]
        for i in 1..<points.count {
            let step = hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            let before = points[max(i - 2, 0)], after = points[min(i + 1, points.count - 1)]
            let heading1 = atan2(points[i].y - before.y, points[i].x - before.x)
            let heading2 = atan2(after.y - points[i - 1].y, after.x - points[i - 1].x)
            var turn = abs(heading2 - heading1)
            if turn > .pi { turn = 2 * .pi - turn }
            let span = max(hypot(after.x - before.x, after.y - before.y), 1e-6)
            let curvature = max(turn / span, 0.002)
            times.append(times[i - 1] + step * pow(curvature, 1.0 / 3))
        }
        let total = times[times.count - 1]
        return times.map { $0 / total }
    }

    private static func encloses(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func distance(from point: CGPoint, toPolyline polyline: [CGPoint]) -> Double {
        var nearest = Double.infinity
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y
            let along = min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-9), 0), 1)
            nearest = min(nearest, hypot(point.x - (a.x + along * dx), point.y - (a.y + along * dy)))
        }
        return nearest
    }
}

nonisolated private struct SplitMix64 {
    var state: UInt64

    init(seeded values: [Double]) {
        state = 0
        for value in values {
            state ^= UInt64(bitPattern: Int64(value.rounded()))
            state = next()
        }
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * Double(next() >> 11) / Double(1 << 53)
    }
}
