import ApplicationServices
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "hotkey")

final class Hotkey {
    private let state: AppState
    private var tap: CFMachPort?
    private var held = false

    init(state: AppState) {
        self.state = state
    }

    func start() async {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(prompt) {
            logger.notice("hotkey waiting for accessibility")
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("hotkey failed tap=nil")
            return
        }
        guard CGEvent.tapIsEnabled(tap: tap) else {
            logger.error("hotkey failed tap=disabled")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        self.tap = tap
        logger.notice("hotkey listening")
    }

    fileprivate func flagsChanged(_ flags: CGEventFlags) {
        let chord = flags.contains([.maskControl, .maskAlternate])
        guard chord != held else { return }
        held = chord
        state.setHeld(chord)
    }
}

private nonisolated func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let flags = event.flags
        let hotkey = Unmanaged<Hotkey>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated { hotkey.flagsChanged(flags) }
    }
    return Unmanaged.passUnretained(event)
}
