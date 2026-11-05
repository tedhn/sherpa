import Foundation

nonisolated struct BarFill: Comparable, Sendable {
    static let empty = BarFill(fraction: 0)

    private static let floorDBFS: Float = -45
    private static let ceilingDBFS: Float = -10

    let fraction: Double

    init(dBFS: Float) {
        self.init(fraction: Double((dBFS - Self.floorDBFS) / (Self.ceilingDBFS - Self.floorDBFS)))
    }

    fileprivate init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }

    static func < (lhs: BarFill, rhs: BarFill) -> Bool { lhs.fraction < rhs.fraction }
}

nonisolated struct LevelMeter: Sendable {
    private static let attack = 0.030
    private static let decay = 0.300

    private var from = BarFill.empty
    private var toward = BarFill.empty
    private var since = ContinuousClock.now

    func fill(at now: ContinuousClock.Instant) -> BarFill {
        let elapsed = since.duration(to: now) / .seconds(1)
        let tau = toward > from ? Self.attack : Self.decay
        return BarFill(fraction: toward.fraction + (from.fraction - toward.fraction) * exp(-elapsed / tau))
    }

    mutating func hear(dBFS: Float, at now: ContinuousClock.Instant) {
        from = fill(at: now)
        toward = BarFill(dBFS: dBFS)
        since = now
    }
}
