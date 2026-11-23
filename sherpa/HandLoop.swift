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

    private static let baseWidth = 3.4
    private static let turns = 1.12
    private static let exponent = 2.6
    private static let leastMargin = 4.0
    private static let cornerClearance = 3.0

    init(around box: CGRect) {
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
                let theta = start - 2 * .pi * Self.turns * t
                var scale = 1 + spiral * (t - 0.5) * 2 / Self.turns
                for wobble in wobbles { scale += wobble.amplitude * sin(wobble.frequency * theta + wobble.phase) }
                let c = cos(theta), s = sin(theta)
                let x = a * scale * (c < 0 ? -1 : 1) * pow(abs(c), 2 / Self.exponent)
                let y = b * scale * (s < 0 ? -1 : 1) * pow(abs(s), 2 / Self.exponent)
                return CGPoint(x: box.midX + shift.x + x * cos(tilt) - y * sin(tilt), y: box.midY + shift.y + x * sin(tilt) + y * cos(tilt))
            }
        }
        let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        func clearsBox(_ margin: Double) -> Bool {
            let points = oval(margin: margin, count: 240)
            let firstTurn = Array(points.prefix(Int(240 / Self.turns) + 1))
            return corners.allSatisfy { Self.encloses(firstTurn, $0) && Self.distance(from: $0, toPolyline: points) >= Self.cornerClearance }
        }
        var low = 0.0, high = 4 * max(box.width, box.height) + 20
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if clearsBox(middle) { high = middle } else { low = middle }
        }
        let margin = max(high, Self.leastMargin)
        let length = Self.turns * 2 * .pi * sqrt(((box.width / 2 + margin) * (box.width / 2 + margin) + (box.height / 2 + margin) * (box.height / 2 + margin)) / 2)
        let count = max(240, Int(length / 2))
        let points = oval(margin: margin, count: count)
        let times = Self.twoThirdsPowerLawTimeShares(of: points)
        nibs = points.indices.map { i in
            let t = Double(i) / Double(count)
            let taperIn = 0.35 + 0.65 * Self.smoothstep(0, 0.1, t)
            let taperOut = 1 - 0.75 * Self.smoothstep(1 - 0.22 / Self.turns, 1, t)
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
