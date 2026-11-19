import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Accessibility and CGEvent share one coordinate space, origin top-left.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first, let directoryPath = arguments.last, arguments.count >= 2 else {
    print("usage: past-sessions-check fixture <journal dir> | window <pid> <journal dir>")
    exit(2)
}
let journal = URL(fileURLWithPath: directoryPath, isDirectory: true)

let fixtureLines: [[String: Any]] = [
    [
        "id": "A1111111-1111-4111-8111-111111111111", "asked": "2026-01-02T09:00:00.000Z", "recalled": 0,
        "question": "Fixture A one", "screens": 1, "answer": "Fixture answer A one",
        "pointed": ["label": "fixture", "screen": 1, "x": 32, "y": 20],
    ],
    [
        "id": "A2222222-2222-4222-8222-222222222222", "asked": "2026-01-02T09:01:00.000Z", "recalled": 1,
        "question": "Fixture A two", "screens": 1, "answer": "Fixture answer A two",
    ],
    [
        "id": "B3333333-3333-4333-8333-333333333333", "asked": "2026-01-03T14:05:00.000Z", "recalled": 0,
        "question": "Fixture B one", "screens": 1, "answer": "Fixture answer B one",
    ],
]
let fixtureShots = ["A1111111-1111-4111-8111-111111111111", "A2222222-2222-4222-8222-222222222222"]

func fixtureText() -> String {
    fixtureLines.map { line in
        let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }.joined()
}

func fixtureJPEG() -> Data {
    let context = CGContext(
        data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

if mode == "fixture" {
    let shots = journal.appending(path: "shots", directoryHint: .isDirectory)
    do {
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try Data(fixtureText().utf8).write(to: journal.appending(path: "exchanges.jsonl"))
        for id in fixtureShots { try fixtureJPEG().write(to: shots.appending(path: "\(id)-1.jpg")) }
    } catch {
        print("  FAIL the fixture was not written: \(error.localizedDescription)")
        exit(1)
    }
    print("  ok   the fixture journal holds Fixture A (2 exchanges) and Fixture B (1 exchange, shot lost) in \(journal.path)")
    exit(0)
}

guard mode == "window", arguments.count == 3, let pid = Int32(arguments[1]) else {
    print("usage: past-sessions-check fixture <journal dir> | window <pid> <journal dir>")
    exit(2)
}

var failures = 0

func ok(_ what: String) { print("  ok   \(what)") }

func fail(_ what: String) {
    print("  FAIL \(what)")
    failures += 1
}

func expect(_ condition: Bool, _ what: String) {
    condition ? ok(what) : fail(what)
}

func wait(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

func wait(upTo seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        wait(0.1)
    }
    return condition()
}

guard AXIsProcessTrusted() else {
    print("  FAIL this terminal has no Accessibility access, so the window cannot be read")
    exit(1)
}

let app = AXUIElementCreateApplication(pid)

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
    return CGRect(origin: origin, size: extent)
}

struct Node {
    let element: AXUIElement
    let role: String
    let texts: [String]
    let frame: CGRect?
}

func walk(_ root: AXUIElement, depth: Int = 14) -> [Node] {
    let texts = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attribute(root, $0) as? String }.filter { !$0.isEmpty }
    let here = Node(element: root, role: attribute(root, kAXRoleAttribute) as? String ?? "", texts: texts, frame: frame(of: root))
    guard depth > 0 else { return [here] }
    return [here] + (attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { walk($0, depth: depth - 1) }
}

func windows() -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

func title(of window: AXUIElement) -> String {
    attribute(window, kAXTitleAttribute) as? String ?? ""
}

func pastSessions() -> AXUIElement? {
    windows().first { title(of: $0) == "Past Sessions" }
}

func osascript(_ source: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func frontmostPid() -> Int32? {
    Int32(osascript("tell application \"System Events\" to return unix id of first process whose frontmost is true"))
}

func statusItem() -> AXUIElement? {
    guard let bar = attribute(app, "AXExtrasMenuBar"), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
    return (attribute(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement])?.first
}

func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    wait(0.05)
}

/// Posted keys reach whichever app is in front, so nothing is sent unless it is Sherpa.
func postKeyToSherpa(_ code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
    guard frontmostPid() == pid else { return false }
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        wait(0.05)
    }
    return true
}

func postModifier(_ virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: virtualKey, keyDown: down) else { return }
    event.type = .flagsChanged
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

let (keyW, keyEscape): (CGKeyCode, CGKeyCode) = (13, 53)
let (leftControl, leftOption): (CGKeyCode, CGKeyCode) = (59, 58)

func journalLines() -> [[String: Any]] {
    let text = (try? String(contentsOf: journal.appending(path: "exchanges.jsonl"), encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}

func journalLog() -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
        "show", "--last", "15m", "--style", "ndjson", "--predicate",
        "processIdentifier == \(pid) AND subsystem == \"my.rooftop.sherpa\" AND category == \"journal\"",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["eventMessage"] as? String
    }
}

func logged(_ prefix: String, count: Int = 1) -> Bool {
    wait(upTo: 10) { journalLog().filter { $0.hasPrefix(prefix) }.count >= count }
}

func openFromMenu() -> Bool {
    guard let item = statusItem(), let rect = frame(of: item) else {
        fail("the status item could not be measured, so there is nothing to aim at")
        return false
    }
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    let cursor = CGEvent(source: nil)?.location ?? centre
    CGWarpMouseCursorPosition(centre)
    wait(0.3)
    post(.rightMouseDown, at: centre, button: .right)
    post(.rightMouseUp, at: centre, button: .right)
    let entry = { walk(item).first { $0.role == kAXMenuItemRole && $0.texts.contains("Past Sessions…") } }
    guard wait(upTo: 5, until: { entry() != nil }), let entry = entry() else {
        CGWarpMouseCursorPosition(cursor)
        return false
    }
    AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
    CGWarpMouseCursorPosition(cursor)
    return true
}

func strings() -> [String] {
    pastSessions().map { walk($0).flatMap(\.texts) } ?? []
}

func sidebar(_ window: AXUIElement) -> [Node] {
    guard let left = frame(of: window)?.minX else { return [] }
    return walk(window).filter { $0.role == kAXStaticTextRole && ($0.frame?.midX ?? .infinity) < left + 300 }
}

func select(rowContaining text: String) {
    guard let window = pastSessions() else { return }
    let rows = walk(window).filter { $0.role == kAXRowRole }
    guard let row = rows.first(where: { walk($0.element).contains { $0.texts.contains(text) } }) else {
        fail("no sidebar row holds '\(text)'")
        return
    }
    if AXUIElementSetAttributeValue(row.element, kAXSelectedAttribute as CFString, kCFBooleanTrue) != .success, let rect = row.frame {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        CGWarpMouseCursorPosition(centre)
        wait(0.2)
        post(.leftMouseDown, at: centre, button: .left)
        post(.leftMouseUp, at: centre, button: .left)
    }
}

let before = frontmostPid()
let windowsBefore = windows().count
let initial = journalLines()
let live = Array(initial.dropFirst(fixtureLines.count))
expect(
    (try? String(contentsOf: journal.appending(path: "exchanges.jsonl"), encoding: .utf8))?.hasPrefix(fixtureText()) == true,
    "the fixture lines at the head of the journal are unchanged, so the app only appended"
)
print("  info \(live.count) live exchange(s) were journalled by the hold section")

guard openFromMenu() else {
    fail("the right-click menu's Past Sessions… item never showed up through Accessibility")
    exit(1)
}
let opened = wait(upTo: 3) { pastSessions() != nil }
expect(opened, "choosing Past Sessions… from the right-click menu opens the window within 3 s")
guard opened, let window = pastSessions() else { exit(1) }
expect(wait(upTo: 3) { frontmostPid() == pid }, "Sherpa is frontmost once the window is open, the front app is \(String(describing: frontmostPid())) not \(pid)")
expect(logged("journal window shown created=yes"), "the log has 'journal window shown created=yes'")
expect(
    logged("journal loaded entries=\(fixtureLines.count) sessions=2 skipped=0 "),
    "the log has the launch's 'journal loaded entries=\(fixtureLines.count) sessions=2 skipped=0', got \(journalLog().filter { $0.hasPrefix("journal loaded") })"
)
let openedFrame = frame(of: window)

wait(1)
let rows = sidebar(window)
let rowTexts = rows.map { $0.texts.first ?? "" }
let order = [live.first?["question"] as? String, "Fixture B one", "Fixture A one"].compactMap { $0 }
let positions = order.compactMap { text in rows.first { $0.texts.contains(text) }?.frame?.minY }
expect(positions.count == order.count && positions == positions.sorted(), "the sidebar lists \(order) top to bottom, got \(rowTexts)")
expect(rowTexts.contains { $0.hasSuffix("· 2 questions") }, "Fixture A's row says 2 questions, got \(rowTexts)")
expect(rowTexts.contains { $0.hasSuffix("· 1 question") }, "Fixture B's row says 1 question, got \(rowTexts)")
if let answer = live.last?["answer"] as? String {
    expect(strings().contains { $0.contains(answer) }, "the detail shows the live session's last answer")
}

let count = journalLines().count
postModifier(leftControl, down: true, flags: .maskControl)
postModifier(leftOption, down: true, flags: [.maskControl, .maskAlternate])
wait(2.5)
postModifier(leftOption, down: false, flags: .maskControl)
postModifier(leftControl, down: false, flags: [])
if wait(upTo: 25, until: { journalLines().count > count }), let question = journalLines().last?["question"] as? String {
    expect(wait(upTo: 2) { strings().contains(question) }, "a new exchange appears in the open window within 2 s of being kept")
    let top = pastSessions().flatMap { sidebar($0).first }?.texts.first
    expect(top == (live.isEmpty ? question : live.first?["question"] as? String), "the newest session is still the top row, got \(String(describing: top))")
    let questionsNow = live.count + 1
    expect(
        pastSessions().map { sidebar($0).contains { ($0.texts.first ?? "").hasSuffix("· \(questionsNow) question\(questionsNow == 1 ? "" : "s")") } } == true,
        "the top row counts \(questionsNow) question(s)"
    )
} else {
    print("  skip live update: no exchange reached the journal within 25 s of a chord hold, so the window was not shown anything new")
}

select(rowContaining: "Fixture B one")
expect(wait(upTo: 3) { strings().contains("Screenshot not kept") }, "Fixture B's lost shot shows 'Screenshot not kept'")

select(rowContaining: "Fixture A one")
expect(wait(upTo: 3) { strings().contains("Fixture answer A two") }, "Fixture A's transcript shows its second answer")
let thumbnail = { pastSessions().flatMap { window in walk(window).first { $0.role == kAXButtonRole && ($0.frame?.height ?? 0) > 100 } } }
if wait(upTo: 3, until: { thumbnail() != nil }), let button = thumbnail() {
    AXUIElementPerformAction(button.element, kAXPressAction as CFString)
    expect(wait(upTo: 3) { windows().count == windowsBefore + 2 }, "pressing a thumbnail opens a second window, Quick Look, got \(windows().map(title(of:)))")
    expect(postKeyToSherpa(keyEscape), "Sherpa is in front for Escape, so the key reaches Quick Look")
    expect(wait(upTo: 3) { windows().count == windowsBefore + 1 }, "Escape closes Quick Look and leaves Past Sessions open")
} else {
    fail("Fixture A shows no thumbnail button to press")
}

expect(postKeyToSherpa(keyW, flags: .maskCommand), "Sherpa is in front for Command-W")
expect(wait(upTo: 3) { pastSessions() == nil }, "Command-W closes the window")
expect(windows().count == windowsBefore, "the app has the \(windowsBefore) window(s) it had before, got \(windows().count)")
expect(kill(pid, 0) == 0, "the app is still running")
expect(statusItem() != nil, "the status item is still there")
expect(wait(upTo: 3) { frontmostPid() == before }, "focus returned to the app in front before, \(String(describing: before)), got \(String(describing: frontmostPid()))")
expect(logged("journal window closed"), "the log has 'journal window closed'")

guard openFromMenu() else {
    // The base build shows the same miss: a posted right-click on a status item only sometimes leaves a menu Accessibility can reach.
    print("  skip reopen: the second right-click menu never showed up through Accessibility")
    exit(failures == 0 ? 0 : 1)
}
expect(wait(upTo: 3) { pastSessions() != nil }, "choosing Past Sessions… again reopens it")
expect(logged("journal window shown created=no"), "the log has 'journal window shown created=no'")
expect(pastSessions().flatMap(frame(of:)) == openedFrame, "the reopened window has the first open's frame, \(String(describing: openedFrame)), got \(String(describing: pastSessions().flatMap(frame(of:))))")
expect(wait(upTo: 3) { frontmostPid() == pid }, "Sherpa is in front again after the reopen")
expect(postKeyToSherpa(keyW, flags: .maskCommand), "Sherpa is in front for the second Command-W")
expect(wait(upTo: 3) { pastSessions() == nil }, "Command-W closes it again, leaving only the panel's state for the teardown")

exit(failures == 0 ? 0 : 1)
