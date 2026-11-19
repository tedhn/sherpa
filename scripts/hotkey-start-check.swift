import ApplicationServices

final class AppState {
    var held: [Bool] = []
    func setHeld(_ held: Bool) { self.held.append(held) }
}

@main
enum HotkeyStartCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String, _ actual: @autoclosure () -> String = "") {
        print(ok ? "  ok   \(what)" : "  FAIL \(what): \(actual())")
        if !ok { failures += 1 }
    }

    static func main() {
        Task {
            await run()
            exit(failures == 0 ? 0 : 1)
        }
        CFRunLoopRun()
    }

    static func ownTaps() -> [CGEventTapInformation] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        return taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }
    }

    static func post(_ virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: virtualKey, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func run() async {
        let state = AppState()
        let hotkey = Hotkey(state: state)

        await hotkey.start()
        await hotkey.start()
        var taps = ownTaps()
        expect(taps.count == 1, "two start() calls leave one tap", "\(taps.count) taps")
        expect(taps.allSatisfy(\.enabled), "the tap is enabled", "\(taps.map(\.enabled))")

        post(59, down: true, flags: .maskControl)
        try? await Task.sleep(for: .milliseconds(100))
        post(58, down: true, flags: [.maskControl, .maskAlternate])
        try? await Task.sleep(for: .milliseconds(600))
        await hotkey.start()
        post(58, down: false, flags: .maskControl)
        try? await Task.sleep(for: .milliseconds(100))
        post(59, down: false, flags: [])
        try? await Task.sleep(for: .milliseconds(300))
        expect(state.held == [true, false], "start() mid-keypress keeps the hold [true, false]", "\(state.held)")
        taps = ownTaps()
        expect(taps.count == 1 && taps.allSatisfy(\.enabled), "still one enabled tap after the keypress", "\(taps.map(\.enabled))")
    }
}
