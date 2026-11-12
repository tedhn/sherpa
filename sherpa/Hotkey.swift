import ApplicationServices
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "hotkey")

final class Hotkey {
    private let state: AppState
    private var tap: CFMachPort?
    private enum Chord {
        case up
        case waiting(Task<Void, Never>)
        case held
        case shortcut
    }

    private static let shortcutWindow = Duration.milliseconds(300)

    private var chord = Chord.up

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
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue | 1 << CGEventType.keyDown.rawValue),
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
        if flags.contains([.maskControl, .maskAlternate]) {
            guard case .up = chord else { return }
            chord = .waiting(Task { [weak self] in
                try? await Task.sleep(for: Hotkey.shortcutWindow)
                guard !Task.isCancelled, let self, case .waiting = chord else { return }
                chord = .held
                state.setHeld(true)
            })
        } else {
            switch chord {
            case .waiting(let task): task.cancel()
            case .held: state.setHeld(false)
            case .up, .shortcut: break
            }
            chord = .up
        }
    }

    fileprivate func reenable(after type: CGEventType) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.notice("hotkey reenabled cause=\(type == .tapDisabledByTimeout ? "timeout" : "input", privacy: .public)")
    }

    fileprivate func keyDown() {
        guard case .waiting(let task) = chord else { return }
        task.cancel()
        chord = .shortcut
        logger.notice("hotkey skipped shortcut")
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
        MainActor.assumeIsolated {
            switch type {
            case .keyDown:
                hotkey.keyDown()
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                hotkey.reenable(after: type)
                // The notice stands in for the event macOS replaced and carries that event's flags.
                fallthrough
            default:
                hotkey.flagsChanged(flags)
            }
        }
    }
    return Unmanaged.passUnretained(event)
}
