import Foundation

@main
enum LevelMeterCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        let t0 = ContinuousClock.now
        func ms(_ n: Int) -> ContinuousClock.Instant { t0 + .milliseconds(n) }

        expect(BarFill(dBFS: -43.7).fraction < 0.10, "the loudest quiet-room buffer (-43.7 dBFS) lights under 10 %")
        expect(BarFill(dBFS: -35).fraction > 0.2, "quiet speech (-35 dBFS) lights over a fifth of the bar")
        expect((0.5...0.9).contains(BarFill(dBFS: -20).fraction), "talking at -20 dBFS lights half to most of the bar")
        expect(BarFill(dBFS: -3).fraction == 1, "a shout pins the bar full")
        expect(BarFill(dBFS: -120).fraction == 0, "digital silence is empty")

        var meter = LevelMeter()
        meter.hear(dBFS: -20, at: ms(0))
        let settled = BarFill(dBFS: -20).fraction
        expect(meter.fill(at: ms(96)).fraction >= 0.9 * settled, "a loud buffer is 90 % drawn before the next one lands")
        expect(meter.fill(at: ms(10)).fraction < 0.5 * settled, "the rise is drawn, not jumped")

        meter.hear(dBFS: -20, at: ms(1000))
        let top = meter.fill(at: ms(1000))
        meter.hear(dBFS: -120, at: ms(1000))
        expect(meter.fill(at: ms(1000)) == top, "a new reading never makes the bar jump")
        expect(meter.fill(at: ms(1250)).fraction >= 0.3 * top.fraction, "a quarter second into silence a third of the word still shows")
        expect(meter.fill(at: ms(2500)).fraction <= 0.01, "a second and a half into silence the bar is empty")

        exit(failures == 0 ? 0 : 1)
    }
}
