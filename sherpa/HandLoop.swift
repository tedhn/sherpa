import CoreGraphics
import Foundation

nonisolated struct HandLoop: Equatable, Sendable {
    struct Nib: Equatable, Sendable {
        let point: CGPoint
        let width: CGFloat
        let timeShare: Double
    }

    let nibs: [Nib]
    let duration: Double

    private static let baseWidth = 3.0
    private static let gap = 6.0
    private static let clearance = 5.0
    private static let roundest = 18.0

    init(around box: CGRect) {
        var rng = SplitMix64(seeded: [box.minX, box.minY, box.width, box.height])
        let wobbles = (0..<3).map { k in
            (amplitude: rng.range(0.3, 0.8) / Double(k + 1), frequency: Double(k + 1) * rng.range(0.8, 1.25), phase: rng.range(0, 2 * .pi))
        }
        let drift = rng.range(1.5, 2.5)
        let long = max(box.width, box.height), short = min(box.width, box.height)
        let tilt = rng.range(-1, 1) * min(1.2, 120 / long) * .pi / 180
        let startShare = rng.range(0.36, 0.44)
        let widthPhase = rng.range(0, 2 * .pi)
        let shift = CGPoint(x: rng.range(-1.5, 1.5), y: rng.range(-0.6, 0.6))

        let outline = Outline(long: long, short: short)
        let overrun = min(max(0.12 * outline.perimeter, 16), 60)
        let length = outline.perimeter + overrun
        let count = max(Int(length / 2), 120)
        let lying = box.width >= box.height
        let points: [CGPoint] = (0...count).map { i in
            let t = Double(i) / Double(count)
            let s = startShare * outline.perimeter + length * t
            let (point, normal) = outline.counterclockwiseFromRightMiddle(s)
            var push = 0.6 - drift * t
            for wobble in wobbles {
                push += wobble.amplitude * sin(2 * .pi * wobble.frequency * 2 * s / outline.perimeter + wobble.phase)
            }
            let x = point.x + normal.x * push, y = point.y + normal.y * push
            let tilted = CGPoint(x: x * cos(tilt) - y * sin(tilt) + shift.x, y: x * sin(tilt) + y * cos(tilt) + shift.y)
            let upright = lying ? tilted : CGPoint(x: -tilted.y, y: tilted.x)
            return CGPoint(x: box.midX + upright.x, y: box.midY + upright.y)
        }
        let times = Self.twoThirdsPowerLawTimeShares(of: points)
        nibs = points.indices.map { i in
            let t = Double(i) / Double(count)
            let taperIn = 0.35 + 0.65 * Self.smoothstep(0, 0.08, t)
            let taperOut = 1 - 0.75 * Self.smoothstep(0.86, 1, t)
            let flutter = 1 + 0.12 * sin(2 * .pi * 1.3 * t + widthPhase)
            return Nib(point: points[i], width: Self.baseWidth * taperIn * taperOut * flutter, timeShare: times[i])
        }
        duration = min(0.38 + 0.14 * log2(max((box.width + box.height) / 60, 1)), 0.75)
    }

    func path(drawnTo share: Double) -> CGPath {
        let path = CGMutablePath()
        guard let first = nibs.first else { return path }
        path.addPath(Self.capsule(from: first.point, to: first.point, width: first.width))
        for (a, b) in zip(nibs, nibs.dropFirst()) where b.timeShare <= share {
            path.addPath(Self.capsule(from: a.point, to: b.point, width: (a.width + b.width) / 2))
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

    private struct Outline {
        let radius: Double, straightX: Double, straightY: Double, perimeter: Double

        init(long: Double, short: Double) {
            radius = min(short / 2 + HandLoop.gap, HandLoop.roundest)
            straightX = long / 2 + Self.endGapClearingCorners(radius: radius) - radius
            straightY = short / 2 + HandLoop.gap - radius
            perimeter = 4 * straightX + 4 * straightY + 2 * .pi * radius
        }

        private static func endGapClearingCorners(radius: Double) -> Double {
            max(HandLoop.gap, radius - sqrt(max(pow(radius - HandLoop.clearance, 2) - pow(radius - HandLoop.gap, 2), 0)))
        }

        func counterclockwiseFromRightMiddle(_ distance: Double) -> (point: CGPoint, normal: CGPoint) {
            var s = distance.truncatingRemainder(dividingBy: perimeter)
            if s < 0 { s += perimeter }
            let quarter = Double.pi * radius / 2
            let (hx, hy, r) = (straightX, straightY, radius)
            func arc(_ cx: Double, _ cy: Double, from start: Double, _ u: Double) -> (CGPoint, CGPoint) {
                let a = start - u / r
                return (CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)), CGPoint(x: cos(a), y: sin(a)))
            }
            let pieces: [(Double, (Double) -> (CGPoint, CGPoint))] = [
                (hy, { (CGPoint(x: hx + r, y: -$0), CGPoint(x: 1, y: 0)) }),
                (quarter, { arc(hx, -hy, from: 0, $0) }),
                (2 * hx, { (CGPoint(x: hx - $0, y: -hy - r), CGPoint(x: 0, y: -1)) }),
                (quarter, { arc(-hx, -hy, from: -.pi / 2, $0) }),
                (2 * hy, { (CGPoint(x: -hx - r, y: -hy + $0), CGPoint(x: -1, y: 0)) }),
                (quarter, { arc(-hx, hy, from: -.pi, $0) }),
                (2 * hx, { (CGPoint(x: -hx + $0, y: hy + r), CGPoint(x: 0, y: 1)) }),
                (quarter, { arc(hx, hy, from: .pi / 2, $0) }),
                (hy, { (CGPoint(x: hx + r, y: hy - $0), CGPoint(x: 1, y: 0)) }),
            ]
            for (length, place) in pieces {
                if s <= length { return place(s) }
                s -= length
            }
            let (length, place) = pieces[pieces.count - 1]
            return place(length)
        }
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
