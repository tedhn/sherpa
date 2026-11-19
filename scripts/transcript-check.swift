import AppKit
import SwiftUI

// Opens Past Sessions inside this process and reads where the cards land
// through Accessibility, so the terminal running it needs that permission.
@main
@MainActor
enum TranscriptCheck {
    static var failures = 0
    static let delegate = Delegate()
    static var window: PastSessionsWindow?

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func main() {
        NSApplication.shared.delegate = delegate
        NSApp.setActivationPolicy(.accessory)
        NSApp.run()
    }

    static func wait(upTo seconds: Double, until done: () -> Bool) async -> Bool {
        let deadline = Date.now + seconds
        while !done() {
            guard Date.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    static func rect(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    // Points from the first element showing exactly this text to the top and
    // bottom of the scroll area holding it. Negative means cut off.
    static func gaps(of text: String) -> (top: Int, bottom: Int)? {
        func find(_ element: AXUIElement, area: CGRect?, depth: Int) -> (top: Int, bottom: Int)? {
            guard depth < 40 else { return nil }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            let area = role as? String == kAXScrollAreaRole ? rect(element) : area
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success, value as? String == text,
               let area, let frame = rect(element) {
                return (Int(frame.minY - area.minY), Int(area.maxY - frame.maxY))
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return nil }
            return list.lazy.compactMap { find($0, area: area, depth: depth + 1) }.first
        }
        return find(AXUIElementCreateApplication(getpid()), area: nil, depth: 0)
    }

    static func show(_ journal: Journal) {
        window = PastSessionsWindow(journal: journal)
        window?.show()
    }

    static func close() {
        NSApp.windows.first { $0.title == "Past Sessions" && $0.isVisible }?.close()
    }

    static func run() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "transcript-check-\(getpid())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = Journal(directory: directory)
        let start = Date.now
        func keep(_ number: Int) async {
            await journal.keep(
                asked: start + Double(number), question: "Question \(number)", screenshots: [],
                answer: "Answer \(number)", pointed: nil, recalled: number - 1
            )
        }

        for number in 1...3 { await keep(number) }
        show(journal)
        expect(await wait(upTo: 3) { gaps(of: "Answer 3") != nil }, "the window shows a 3-question session")
        let first = gaps(of: "Answer 1")
        expect((first?.top ?? .max) < 100, "a short session starts at the top, its first answer sits \(String(describing: first?.top)) pt below it")
        close()

        for number in 4...40 { await keep(number) }
        show(journal)
        expect(
            await wait(upTo: 3) { gaps(of: "Answer 40")?.bottom == 24 },
            "a 40-question session opens on its last answer, 24 pt above the bottom, got \(String(describing: gaps(of: "Answer 40")))"
        )
        await keep(41)
        expect(
            await wait(upTo: 2) { gaps(of: "Answer 41")?.bottom == 24 },
            "an answer kept while the window is open scrolls into view within 2 s, got \(String(describing: gaps(of: "Answer 41")))"
        )
        close()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await TranscriptCheck.run()
            exit(TranscriptCheck.failures == 0 ? 0 : 1)
        }
    }
}
