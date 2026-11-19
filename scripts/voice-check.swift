import AppKit
import CoreGraphics
import Foundation

enum Anchor {
    case leading, center, trailing
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct Canvas {
    static let width: CGFloat = 1280
    static let height: CGFloat = 832

    private func flipped(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> NSRect {
        NSRect(x: x, y: Canvas.height - y - height, width: width, height: height)
    }

    func fill(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        NSBezierPath(roundedRect: flipped(x, y, width, height), xRadius: radius, yRadius: radius).fill()
    }

    func outline(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: NSColor, radius: CGFloat = 0, thickness: CGFloat = 1) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: flipped(x, y, width, height), xRadius: radius, yRadius: radius)
        path.lineWidth = thickness
        path.stroke()
    }

    func oval(_ x: CGFloat, _ y: CGFloat, _ diameter: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: flipped(x, y, diameter, diameter)).fill()
    }

    func line(from start: CGPoint, to end: CGPoint, _ color: NSColor, thickness: CGFloat = 1) {
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: start.x, y: Canvas.height - start.y))
        path.line(to: CGPoint(x: end.x, y: Canvas.height - end.y))
        path.lineWidth = thickness
        path.stroke()
    }

    func squiggle(from start: CGFloat, to end: CGFloat, y: CGFloat, _ color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: start, y: Canvas.height - y))
        var x = start
        var up = true
        while x < end {
            x += 3
            path.line(to: CGPoint(x: x, y: Canvas.height - y + (up ? 3 : 0)))
            up.toggle()
        }
        path.lineWidth = 1.5
        path.stroke()
    }

    func gradient(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, from: NSColor, to: NSColor) {
        NSGradient(starting: from, ending: to)?.draw(in: flipped(x, y, width, height), angle: 45)
    }

    func clipped(toRoundedRect x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, radius: CGFloat, drawing: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: flipped(x, y, width, height), xRadius: radius, yRadius: radius).addClip()
        drawing()
        NSGraphicsContext.restoreGraphicsState()
    }

    func trafficLights(x: CGFloat, y: CGFloat) {
        oval(x, y, 14, NSColor(hex: 0xFF5F57))
        oval(x + 22, y, 14, NSColor(hex: 0xFEBC2E))
        oval(x + 44, y, 14, NSColor(hex: 0x28C840))
    }

    func menuBar(_ items: [String], background: NSColor, color: NSColor) {
        fill(0, 0, Canvas.width, 28, background)
        var x: CGFloat = 20
        for (index, item) in items.enumerated() {
            x += text(item, x: x, y: 6, size: 14, color: color, weight: index == 1 ? .bold : .regular) + 22
        }
        text("Wed 10:42", x: Canvas.width - 20, y: 6, size: 14, color: color, anchor: .trailing)
    }

    @discardableResult
    func text(
        _ string: String, x: CGFloat, y: CGFloat, size: CGFloat = 16, color: NSColor = NSColor(hex: 0x1D1D1F),
        weight: NSFont.Weight = .regular, mono: Bool = false, anchor: Anchor = .leading
    ) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = string.size(withAttributes: attributes)
        let left: CGFloat
        switch anchor {
        case .leading: left = x
        case .center: left = x - measured.width / 2
        case .trailing: left = x - measured.width
        }
        string.draw(at: NSPoint(x: left, y: Canvas.height - y - measured.height), withAttributes: attributes)
        return measured.width
    }

    func width(of string: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return string.size(withAttributes: [.font: font]).width
    }
}

struct Scene {
    let name: String
    var cursor = true
    let draw: (Canvas) -> Void

    var away: Scene {
        var copy = self
        copy.cursor = false
        return copy
    }

    func image() -> CGImage {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(Canvas.width), pixelsHigh: Int(Canvas.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        draw(Canvas())
        NSGraphicsContext.restoreGraphicsState()
        return representation.cgImage!
    }

    func screenshot(display: CGDirectDisplayID) -> Screenshot {
        Screenshot(
            encoding: image(), display: display,
            appKitFrame: CGRect(x: 0, y: 0, width: Canvas.width, height: Canvas.height),
            cursor: cursor ? CGPoint(x: Canvas.width / 2, y: Canvas.height / 2) : CGPoint(x: -500, y: -500)
        )!
    }

    func png() -> Data {
        NSBitmapImageRep(cgImage: image()).representation(using: .png, properties: [:])!
    }
}

extension Scene {
    static let all = [xcodeError, recipe, spreadsheet, wifiSettings, chat]

    static let xcodeError = Scene(name: "xcodeError") { canvas in
        let keyword = NSColor(hex: 0xFC5FA3)
        let type = NSColor(hex: 0x5DD8FF)
        let plain = NSColor(hex: 0xD4D4D4)
        let function = NSColor(hex: 0xA167E6)
        let gutterWidth: CGFloat = 70
        canvas.fill(0, 0, Canvas.width, Canvas.height, NSColor(hex: 0x1E1E1E))
        canvas.menuBar(["Xcode", "File", "Edit", "View", "Navigate", "Editor", "Product", "Window", "Help"], background: NSColor(hex: 0x2A2A2C), color: NSColor(hex: 0xE5E5E7))
        canvas.fill(0, 28, Canvas.width, 44, NSColor(hex: 0x2D2D30))
        canvas.trafficLights(x: 20, y: 43)
        canvas.text("NetworkClient.swift", x: Canvas.width / 2, y: 40, size: 16, color: NSColor(hex: 0xE0E0E0), weight: .semibold, anchor: .center)
        canvas.text("Build Failed", x: Canvas.width - 24, y: 41, size: 15, color: NSColor(hex: 0xFF6B6B), weight: .medium, anchor: .trailing)
        canvas.fill(0, 72, Canvas.width, 30, NSColor(hex: 0x252526))
        canvas.text("Sherpa  \u{203A}  Networking  \u{203A}  NetworkClient.swift", x: 20, y: 80, size: 13, color: NSColor(hex: 0x9A9A9A))
        canvas.fill(0, 102, gutterWidth, Canvas.height - 102, NSColor(hex: 0x252526))
        let lines: [[(String, NSColor)]] = [
            [("import ", keyword), ("Foundation", type)],
            [],
            [("final class ", keyword), ("NetworkClient ", type), ("{", plain)],
            [("    let ", keyword), ("session = ", plain), ("URLSession", type), (".shared", plain)],
            [],
            [("    func ", keyword), ("fetch", function), ("(_ url: ", plain), ("URL", type), (") ", plain), ("async throws ", keyword), ("{", plain)],
            [("        let ", keyword), ("(data, response) = ", plain), ("try await ", keyword), ("session.data(from: url)", plain)],
            [("        print(", plain), ("reponse", plain), (".statusCode)", plain)],
            [("        print(", plain), ("data.count)", plain)],
            [("    }", plain)],
            [("}", plain)],
        ]
        let errorLine = 8
        for (index, segments) in lines.enumerated() {
            let number = index + 1
            let top = CGFloat(120 + index * 30)
            if number == errorLine {
                canvas.fill(gutterWidth, top - 4, Canvas.width - gutterWidth, 30, NSColor(hex: 0x4A1D1D))
                canvas.oval(14, top + 1, 20, NSColor(hex: 0xE5484D))
                canvas.text("!", x: 24, y: top + 2, size: 15, color: .white, weight: .bold, anchor: .center)
            }
            canvas.text("\(number)", x: gutterWidth - 16, y: top, size: 16, color: NSColor(hex: 0x6E6E6E), mono: true, anchor: .trailing)
            var x = gutterWidth + 20
            for (text, color) in segments {
                if number == errorLine, text == "reponse" {
                    let width = canvas.text(text, x: x, y: top, size: 18, color: color, mono: true)
                    canvas.squiggle(from: x, to: x + width, y: top + 22, NSColor(hex: 0xFF4D4F))
                    x += width
                } else {
                    x += canvas.text(text, x: x, y: top, size: 18, color: color, mono: true)
                }
            }
            if number == errorLine {
                let message = "Cannot find 'reponse' in scope"
                let width = canvas.width(of: message, size: 15) + 28
                canvas.fill(x + 36, top - 1, width, 26, NSColor(hex: 0xC42B2B), radius: 5)
                canvas.text(message, x: x + 50, y: top + 3, size: 15, color: .white)
            }
        }
    }

    static let recipe = Scene(name: "recipe") { canvas in
        let ink = NSColor(hex: 0x222222)
        let muted = NSColor(hex: 0x666666)
        canvas.fill(0, 0, Canvas.width, Canvas.height, .white)
        canvas.menuBar(["Safari", "File", "Edit", "View", "History", "Bookmarks", "Window", "Help"], background: NSColor(hex: 0xF2F2F2), color: NSColor(hex: 0x1D1D1F))
        canvas.fill(0, 28, Canvas.width, 56, NSColor(hex: 0xE8E8EA))
        canvas.trafficLights(x: 20, y: 49)
        canvas.fill(340, 40, 600, 32, .white, radius: 8)
        canvas.text("bananabread.example/classic", x: 640, y: 47, size: 15, color: muted, anchor: .center)
        canvas.text("Baking", x: 200, y: 112, size: 16, color: NSColor(hex: 0xC2570C), weight: .semibold)
        canvas.text("Banana Bread", x: 200, y: 136, size: 52, color: ink, weight: .bold)
        canvas.text("A simple loaf that uses up overripe bananas. Makes one loaf.", x: 200, y: 204, size: 20, color: muted)
        canvas.text("Ingredients", x: 200, y: 260, size: 30, color: ink, weight: .bold)
        let ingredients = ["3 ripe bananas", "1/3 cup melted butter", "3/4 cup sugar", "1 tsp baking soda", "1 1/2 cups flour", "Pinch of salt"]
        for (index, ingredient) in ingredients.enumerated() {
            let top = CGFloat(312 + index * 40)
            canvas.oval(202, top + 10, 9, NSColor(hex: 0xC2570C))
            canvas.text(ingredient, x: 226, y: top, size: 24, color: ink)
        }
        canvas.text("Method", x: 200, y: 572, size: 30, color: ink, weight: .bold)
        let method = [
            "Preheat the oven to 350\u{00B0}F. Mash the bananas in a large bowl, then stir in the",
            "melted butter. Mix in the sugar and baking soda, add the salt, and fold in the",
            "flour until just combined. Pour into a greased loaf pan and bake for 60 min,",
            "until a toothpick comes out clean.",
        ]
        for (index, line) in method.enumerated() {
            canvas.text(line, x: 200, y: CGFloat(624 + index * 34), size: 22, color: ink)
        }
    }

    static let spreadsheet = Scene(name: "spreadsheet") { canvas in
        let grid = NSColor(hex: 0xD0D0D4)
        let ink = NSColor(hex: 0x1D1D1F)
        let headerWidth: CGFloat = 60
        let columns: [(letter: String, x: CGFloat, width: CGFloat)] = [("A", 60, 260), ("B", 320, 220), ("C", 540, 220), ("D", 760, 220)]
        let rows = [
            ["Month", "Revenue", "Costs"],
            ["July", "4,200", "2,900"],
            ["August", "3,800", "3,100"],
            ["September", "4,400", "2,700"],
            ["Total", "12,400", "8,700"],
        ]
        canvas.fill(0, 0, Canvas.width, Canvas.height, .white)
        canvas.menuBar(["Sheets", "File", "Edit", "View", "Insert", "Format", "Data", "Window", "Help"], background: NSColor(hex: 0xF2F2F2), color: ink)
        canvas.fill(0, 28, Canvas.width, 44, NSColor(hex: 0xE8E8EA))
        canvas.trafficLights(x: 20, y: 43)
        canvas.text("Q3 budget", x: Canvas.width / 2, y: 40, size: 16, color: ink, weight: .semibold, anchor: .center)
        canvas.fill(0, 72, Canvas.width, 40, NSColor(hex: 0xF6F6F8))
        canvas.fill(16, 78, 70, 28, .white, radius: 4)
        canvas.outline(16, 78, 70, 28, grid, radius: 4)
        canvas.text("B5", x: 51, y: 83, size: 16, color: ink, anchor: .center)
        canvas.text("fx", x: 108, y: 82, size: 17, color: NSColor(hex: 0x777777), weight: .medium)
        canvas.text("=SUM(B2:B4)", x: 146, y: 82, size: 18, color: ink, mono: true)
        let top: CGFloat = 112
        canvas.fill(0, top, Canvas.width, 32, NSColor(hex: 0xEEEEF0))
        for column in columns {
            canvas.text(column.letter, x: column.x + column.width / 2, y: top + 7, size: 16, color: NSColor(hex: 0x555555), anchor: .center)
        }
        let rowHeight: CGFloat = 40
        let rowCount = 15
        for row in 0..<rowCount {
            let y = top + 32 + CGFloat(row) * rowHeight
            canvas.fill(0, y, headerWidth, rowHeight, NSColor(hex: 0xEEEEF0))
            canvas.text("\(row + 1)", x: headerWidth / 2, y: y + 11, size: 16, color: NSColor(hex: 0x555555), anchor: .center)
            if row == 0 { canvas.fill(headerWidth, y, 920, rowHeight, NSColor(hex: 0xF4F4F6)) }
            canvas.line(from: CGPoint(x: 0, y: y + rowHeight), to: CGPoint(x: 980, y: y + rowHeight), grid)
            guard row < rows.count else { continue }
            let bold = row == 0 || row == rows.count - 1
            for (index, value) in rows[row].enumerated() {
                let column = columns[index]
                if index == 0 {
                    canvas.text(value, x: column.x + 12, y: y + 9, size: 20, color: ink, weight: bold ? .bold : .regular)
                } else {
                    canvas.text(value, x: column.x + column.width - 12, y: y + 9, size: 20, color: ink, weight: bold ? .bold : .regular, anchor: .trailing)
                }
            }
        }
        let bottom = top + 32 + CGFloat(rowCount) * rowHeight
        for x in [headerWidth] + columns.map({ $0.x + $0.width }) {
            canvas.line(from: CGPoint(x: x, y: top), to: CGPoint(x: x, y: bottom), grid)
        }
        canvas.line(from: CGPoint(x: 0, y: top + 32), to: CGPoint(x: 980, y: top + 32), grid)
        let selected = top + 32 + 4 * rowHeight
        canvas.outline(320, selected, 220, rowHeight, NSColor(hex: 0x1A73E8), thickness: 3)
        canvas.fill(0, 790, Canvas.width, 42, NSColor(hex: 0xF2F2F4))
        canvas.fill(16, 796, 110, 30, .white, radius: 6)
        canvas.text("Q3 budget", x: 71, y: 802, size: 15, color: ink, weight: .medium, anchor: .center)
    }

    static let wifiSettings = Scene(name: "wifiSettings") { canvas in
        let ink = NSColor(hex: 0x1D1D1F)
        let muted = NSColor(hex: 0x6E6E73)
        canvas.gradient(0, 0, Canvas.width, Canvas.height, from: NSColor(hex: 0x3B5BDB), to: NSColor(hex: 0x9C36B5))
        canvas.menuBar(["System Settings", "File", "Edit", "View", "Window", "Help"], background: NSColor(hex: 0x1C1C2E), color: .white)
        canvas.fill(190, 90, 900, 640, NSColor(hex: 0xF5F5F7), radius: 14)
        canvas.clipped(toRoundedRect: 190, 90, 900, 640, radius: 14) {
            canvas.fill(190, 90, 270, 640, NSColor(hex: 0xE6E6EB))
        }
        canvas.trafficLights(x: 210, y: 108)
        canvas.fill(206, 142, 238, 34, .white, radius: 8)
        canvas.text("Search", x: 224, y: 150, size: 16, color: NSColor(hex: 0x9A9AA0))
        let items = ["Wi-Fi", "Bluetooth", "Network", "Notifications", "Sound", "Focus", "Screen Time", "General"]
        let icons: [UInt32] = [0x0A84FF, 0x1E90FF, 0x30B0C7, 0xFF453A, 0xFF9F0A, 0x7D5BDB, 0x5E5CE6, 0x8E8E93]
        for (index, item) in items.enumerated() {
            let top = CGFloat(194 + index * 46)
            let selected = index == 0
            if selected { canvas.fill(204, top, 242, 40, NSColor(hex: 0x0A84FF), radius: 8) }
            canvas.fill(214, top + 8, 24, 24, selected ? NSColor(hex: 0x6CB8FF) : NSColor(hex: icons[index]), radius: 6)
            canvas.text(item, x: 250, y: top + 10, size: 17, color: selected ? .white : ink)
        }
        canvas.text("Wi-Fi", x: 500, y: 112, size: 30, color: ink, weight: .bold)
        canvas.fill(490, 170, 570, 58, .white, radius: 10)
        canvas.text("Wi-Fi", x: 512, y: 187, size: 18, color: ink)
        canvas.fill(990, 184, 52, 30, NSColor(hex: 0xC7C7CC), radius: 15)
        canvas.oval(992, 186, 26, .white)
        canvas.text("Wi-Fi is turned off", x: 775, y: 400, size: 22, color: muted, weight: .medium, anchor: .center)
        canvas.text("Turn on Wi-Fi to see available networks.", x: 775, y: 436, size: 16, color: NSColor(hex: 0x9A9AA0), anchor: .center)
    }

    static let chat = Scene(name: "chat") { canvas in
        let ink = NSColor(hex: 0x1D1D1F)
        let muted = NSColor(hex: 0x6E6E73)
        canvas.fill(0, 0, Canvas.width, Canvas.height, .white)
        canvas.menuBar(["Messages", "File", "Edit", "View", "Conversations", "Window", "Help"], background: NSColor(hex: 0xF2F2F2), color: ink)
        canvas.fill(0, 28, 340, Canvas.height - 28, NSColor(hex: 0xF2F2F5))
        canvas.trafficLights(x: 20, y: 46)
        canvas.text("Messages", x: 20, y: 80, size: 26, color: ink, weight: .bold)
        let people = [
            ("Priya", "Can you send me the slides\u{2026}", 0x7D5BDB),
            ("Marcus", "Lunch tomorrow?", 0x30B0C7),
            ("Design team", "Figma link updated", 0xFF9F0A),
            ("Mom", "Call me when you're free", 0xFF453A),
        ]
        for (index, person) in people.enumerated() {
            let top = CGFloat(130 + index * 80)
            if index == 0 { canvas.fill(10, top - 6, 320, 72, NSColor(hex: 0xD8E6FF), radius: 10) }
            canvas.oval(24, top + 2, 50, NSColor(hex: UInt32(person.2)))
            canvas.text(String(person.0.prefix(1)), x: 49, y: top + 14, size: 22, color: .white, weight: .semibold, anchor: .center)
            canvas.text(person.0, x: 90, y: top + 2, size: 17, color: ink, weight: .semibold)
            canvas.text(person.1, x: 90, y: top + 28, size: 14, color: muted)
        }
        canvas.line(from: CGPoint(x: 340, y: 28), to: CGPoint(x: 340, y: Canvas.height), NSColor(hex: 0xD8D8DC))
        canvas.fill(341, 28, Canvas.width - 341, 64, NSColor(hex: 0xFAFAFA))
        canvas.line(from: CGPoint(x: 341, y: 92), to: CGPoint(x: Canvas.width, y: 92), NSColor(hex: 0xD8D8DC))
        canvas.text("Priya", x: 810, y: 48, size: 20, color: ink, weight: .semibold, anchor: .center)
        canvas.text("Today 1:42 PM", x: 810, y: 124, size: 13, color: muted, anchor: .center)
        let messages: [(String, Bool)] = [
            ("Hey! How's the deck coming along?", false),
            ("Almost done. Just polishing the last few slides.", true),
            ("Can you send me the slides before 3pm?", false),
        ]
        for (index, message) in messages.enumerated() {
            let top = CGFloat(160 + index * 76)
            let width = canvas.width(of: message.0, size: 20) + 36
            let x = message.1 ? Canvas.width - 30 - width : 372
            canvas.fill(x, top, width, 48, message.1 ? NSColor(hex: 0x0A84FF) : NSColor(hex: 0xE9E9EB), radius: 22)
            canvas.text(message.0, x: x + 18, y: top + 13, size: 20, color: message.1 ? .white : ink)
        }
        canvas.fill(372, 760, 880, 44, .white, radius: 22)
        canvas.outline(372, 760, 880, 44, NSColor(hex: 0xC7C7CC), radius: 22)
        canvas.text("Message", x: 396, y: 772, size: 17, color: NSColor(hex: 0x9A9AA0))
    }
}

struct Turn {
    let question: String
    let scenes: [Scene]
    var maxWords = 70
    var mustMention: [[String]] = []
    var mustNotMention: [String] = []
    var allowed: [String] = []
}

struct Case {
    let name: String
    let turns: [Turn]
}

struct Finding: Equatable {
    let rule: String
    let snippet: String
}

struct Rule {
    let name: String
    let offense: (String, Turn) -> String?

    static func words(in answer: String) -> Int {
        answer.split(whereSeparator: \.isWhitespace).count
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let start = text.index(range.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
        return text[start..<end].replacingOccurrences(of: "\n", with: " / ")
    }

    private static func pattern(_ name: String, _ pattern: String) -> Rule {
        Rule(name: name) { answer, _ in match(pattern, in: answer) }
    }

    static let all: [Rule] = [
        pattern("markdown", #"[*`#|]|__|\[[^\]]*\]\([^)]*\)"#),
        pattern("list", #"(?m)^[ \t]*(?:[-\#u{2022}]|\d+[.)])[ \t]"#),
        Rule(name: "paragraphs") { answer, _ in
            let lines = answer.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
            return lines.count > 2 ? "\(lines.count) lines" : nil
        },
        pattern(
            "abbreviation",
            #"\be\.g\.|\bi\.e\.|\betc\b|\bvs\b|\bapprox\b|\bw/|&|\#u{2192}|~|[\#u{2318}\#u{2325}\#u{21E7}\#u{2303}]|\b(?:cmd|ctrl|opt)\b|\d ?(?:km|kg|lbs?|oz|tsp|tbsp|mins?|hrs?|secs?|ms|mph|ft|cm|mm)\b|\d/\d|\#u{00B0}"#
        ),
        pattern("link", #"http|www\.|~/|/Users/"#),
        pattern("code", #"\w\(|[{}=]"#),
        Rule(name: "emoji") { answer, _ in
            answer.unicodeScalars.first(where: \.properties.isEmojiPresentation).map { String($0) }
        },
        pattern("narration", #"\bscreenshots?\b|\bimages?\b|as an ai|language model"#),
        pattern("opener", #"^(?:great question|sure|certainly|of course|absolutely|happy to)\b"#),
        Rule(name: "length") { answer, turn in
            let count = words(in: answer)
            return count > turn.maxWords ? "\(count) words, limit \(turn.maxWords)" : nil
        },
        Rule(name: "mustMention") { answer, turn in
            let lowered = answer.lowercased()
            let missing = turn.mustMention.filter { group in !group.contains { lowered.contains($0.lowercased()) } }
            return missing.isEmpty ? nil : "missing " + missing.map { $0.joined(separator: " / ") }.joined(separator: "; ")
        },
        Rule(name: "mustNotMention") { answer, turn in
            let lowered = answer.lowercased()
            let found = turn.mustNotMention.filter { lowered.contains($0.lowercased()) }
            return found.isEmpty ? nil : "found " + found.joined(separator: ", ")
        },
    ]

    static func findings(in answer: String, for turn: Turn) -> [Finding] {
        all.compactMap { rule in
            guard !turn.allowed.contains(rule.name), let snippet = rule.offense(answer, turn) else { return nil }
            return Finding(rule: rule.name, snippet: snippet)
        }
    }
}

extension Case {
    private static let buildTypo = [["reponse", "response", "typo", "misspel", "spelled"]]

    static let all: [Case] = [
        Case(name: "error", turns: [Turn(question: "Why won't this build?", scenes: [.xcodeError], mustMention: buildTypo)]),
        Case(name: "misheard", turns: [Turn(question: "Why won't this bill?", scenes: [.xcodeError], mustMention: buildTypo)]),
        Case(name: "irrelevant", turns: [Turn(
            question: "What's a good name for a golden retriever puppy?", scenes: [.spreadsheet],
            mustNotMention: ["screen", "spreadsheet", "budget", "revenue"]
        )]),
        Case(name: "shortcut", turns: [Turn(
            question: "How do I take a screenshot of just part of my screen?", scenes: [.wifiSettings],
            mustMention: [["command"], ["shift"], ["four", "4"]], allowed: ["narration"]
        )]),
        Case(name: "steps", turns: [Turn(question: "How do I set up an SSH key for GitHub?", scenes: [.xcodeError], maxWords: 90)]),
        Case(name: "recipe", turns: [Turn(
            question: "How much butter and sugar do I need?", scenes: [.recipe],
            mustMention: [["butter"], ["sugar"], ["third"], ["three quarter", "three-quarter", "3 quarter"]]
        )]),
        Case(name: "oven", turns: [Turn(
            question: "What temperature and how long?", scenes: [.recipe],
            mustMention: [["350", "three fifty", "three hundred fifty", "three hundred and fifty"], ["hour", "sixty minutes", "60 minutes"]]
        )]),
        Case(name: "spreadsheet", turns: [Turn(
            question: "What's the total revenue?", scenes: [.spreadsheet],
            mustMention: [["12,400", "12400", "twelve thousand four hundred"]]
        )]),
        Case(name: "describe", turns: [Turn(question: "What am I looking at?", scenes: [.chat, Scene.xcodeError.away], maxWords: 60)]),
        Case(name: "notVisible", turns: [Turn(
            question: "What did Priya say in her last message?", scenes: [.spreadsheet, Scene.wifiSettings.away],
            mustMention: [["don't see", "can't see", "not seeing", "isn't on", "not on your screen", "don't have", "can't find", "not showing", "no message"]],
            mustNotMention: ["slides"]
        )]),
        Case(name: "reply", turns: [Turn(question: "What should I tell her?", scenes: [.chat], mustMention: [["slides"]])]),
        Case(name: "followUp", turns: [
            Turn(question: "Why won't this build?", scenes: [.xcodeError]),
            Turn(question: "Okay, how do I fix it?", scenes: [.xcodeError], mustMention: [["response"]]),
        ]),
        Case(name: "code", turns: [Turn(
            question: "How do I reverse a string in Swift?", scenes: [.spreadsheet],
            mustMention: [["reversed"]], mustNotMention: ["spreadsheet", "screen"]
        )]),
        Case(name: "wifi", turns: [Turn(question: "Why can't I get online?", scenes: [.wifiSettings], mustMention: [["wi-fi", "wifi", "wi fi"]])]),
    ]
}

struct Options {
    var runs = 1
    var only: Set<String>?
    var scenes: String?
    var out: String?
    var selfTest = false

    init(_ arguments: [String]) {
        var rest = arguments.dropFirst()[...]
        func value(_ flag: String) -> String {
            guard let next = rest.popFirst() else { Options.usage("\(flag) needs a value") }
            return next
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--runs":
                guard let count = Int(value(argument)), count > 0 else { Options.usage("--runs needs a positive number") }
                runs = count
            case "--only": only = Set(value(argument).split(separator: ",").map(String.init))
            case "--scenes": scenes = value(argument)
            case "--out": out = value(argument)
            case "--self-test": selfTest = true
            default: Options.usage("unknown argument \(argument)")
            }
        }
    }

    static func usage(_ problem: String) -> Never {
        print("\(problem)\nusage: voice-check [--runs N] [--only name,name] [--scenes DIR] [--out FILE] [--self-test]")
        exit(2)
    }
}

struct Tally {
    var answers = 0
    var failed = 0
    var byRule: [String: Int] = [:]
}

@main
enum VoiceCheck {
    static func main() async {
        let options = Options(CommandLine.arguments)
        if options.selfTest { exit(selfTest() ? 0 : 1) }
        if let directory = options.scenes { writeScenes(to: directory) }
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            print("skip no ANTHROPIC_API_KEY")
            exit(0)
        }
        let names = Set(Case.all.map(\.name))
        if let unknown = options.only?.subtracting(names), !unknown.isEmpty {
            Options.usage("unknown case \(unknown.sorted().joined(separator: ", ")); cases are \(Case.all.map(\.name).joined(separator: ", "))")
        }
        let cases = Case.all.filter { options.only?.contains($0.name) ?? true }
        let tally = await run(cases, runs: options.runs, key: key, outPath: options.out)
        printSummary(tally)
        exit(tally.failed == 0 ? 0 : 1)
    }

    static func writeScenes(to directory: String) {
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for scene in Scene.all {
                try scene.png().write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(scene.name).png"))
            }
            print("wrote \(Scene.all.count) scenes to \(directory)")
        } catch {
            print("FAIL writing scenes: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run(_ cases: [Case], runs: Int, key: String, outPath: String?) async -> Tally {
        var tally = Tally()
        var out: FileHandle?
        if let outPath {
            FileManager.default.createFile(atPath: outPath, contents: nil)
            out = FileHandle(forWritingAtPath: outPath)
        }
        var utterance = 0
        for current in cases {
            for run in 1...runs {
                let conversation = Conversation(endpoint: Claude.Endpoint(url: Claude.Endpoint.production, key: key), urlSession: .shared)
                for (index, turn) in current.turns.enumerated() {
                    utterance += 1
                    let question = Claude.Question(
                        text: turn.question,
                        screenshots: turn.scenes.enumerated().map { $1.screenshot(display: CGDirectDisplayID($0 + 1)) }
                    )
                    print("\(current.name) run \(run) turn \(index + 1)\n  Q: \(turn.question)")
                    let started = ContinuousClock.now
                    let elapsed = { Int((started.duration(to: .now) / .milliseconds(1)).rounded()) }
                    var first = 0
                    var answer = ""
                    var findings: [Finding] = []
                    do throws(Claude.Failure) {
                        answer = try await conversation.answer(question, utterance: utterance) { _ in
                            if first == 0 { first = elapsed() }
                        }
                        findings = Rule.findings(in: answer, for: turn)
                    } catch {
                        findings = [Finding(rule: "api", snippet: error.logFields)]
                    }
                    let total = elapsed()
                    let words = Rule.words(in: answer)
                    if !answer.isEmpty {
                        print(answer.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { "  \($0 == 0 ? "A:" : "  ") \($1)" }.joined(separator: "\n"))
                    }
                    print("  \(words) words, first text \(first) ms, total \(total) ms")
                    if findings.isEmpty {
                        print("  ok")
                    } else {
                        for finding in findings { print("  FAIL \(finding.rule): \(finding.snippet)") }
                    }
                    tally.answers += 1
                    if !findings.isEmpty { tally.failed += 1 }
                    for finding in findings { tally.byRule[finding.rule, default: 0] += 1 }
                    let record: [String: Any] = [
                        "case": current.name, "run": run, "turn": index + 1, "question": turn.question, "answer": answer,
                        "words": words, "firstMs": first, "totalMs": total,
                        "failures": findings.map { "\($0.rule): \($0.snippet)" },
                    ]
                    if let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) {
                        out?.write(line + Data("\n".utf8))
                    }
                }
            }
        }
        try? out?.close()
        return tally
    }

    static func printSummary(_ tally: Tally) {
        print("summary")
        for name in Rule.all.map(\.name) + ["api"] {
            print("  \(name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(tally.byRule[name, default: 0])")
        }
        print("  failing answers \(tally.failed) of \(tally.answers)")
    }

    static func selfTest() -> Bool {
        struct Probe {
            let text: String
            var turn = Turn(question: "", scenes: [])
            let failing: [String]
        }
        let probes = [
            Probe(text: "Press Cmd+Shift+4.", failing: ["abbreviation"]),
            Probe(text: "Press Command Shift 4.", failing: []),
            Probe(text: "1. Open Terminal\n2. Run ssh-keygen", failing: ["list"]),
            Probe(text: "- Open Terminal", failing: ["list"]),
            Probe(text: "Use `reversed()`", failing: ["markdown", "code"]),
            Probe(text: "That is **bold**.", failing: ["markdown"]),
            Probe(text: "See [the docs](https://example.com).", failing: ["markdown", "link"]),
            Probe(text: "About a third of a cup of butter.", failing: []),
            Probe(text: "It's at 350\u{00B0}F", failing: ["abbreviation"]),
            Probe(text: "Bake for 60 min.", failing: ["abbreviation"]),
            Probe(text: "Bake for about an hour.", failing: []),
            Probe(text: "Bake for sixty minutes, about 5 minutes more.", failing: []),
            Probe(text: "Use 1/3 cup of sugar.", failing: ["abbreviation"]),
            Probe(text: "Mix flour & sugar.", failing: ["abbreviation"]),
            Probe(text: "That takes approximately ten minutes.", failing: []),
            Probe(text: "Options exist, e.g. this one.", failing: ["abbreviation"]),
            Probe(text: "Press \u{2318} and Q.", failing: ["abbreviation"]),
            Probe(text: "Look in ~/Documents.", failing: ["abbreviation", "link"]),
            Probe(text: "Go to www.example.com.", failing: ["link"]),
            Probe(text: "That looks fine \u{1F600}", failing: ["emoji"]),
            Probe(text: "Type String(yourString.reversed()).", failing: ["code"]),
            Probe(text: "The cell reads =SUM of the column.", failing: ["code"]),
            Probe(text: "Call reversed on it and wrap the result in String.", failing: []),
            Probe(text: "Your Wi-Fi (the top switch) is off.", failing: []),
            Probe(text: "It's misspelled; fix line 8.", failing: []),
            Probe(text: "Step 4 is next.", failing: []),
            Probe(text: "One.\nTwo.\nThree.", failing: ["paragraphs"]),
            Probe(text: "One.\n\nTwo.", failing: []),
            Probe(text: "Take a screenshot with Command Shift Four.", failing: ["narration"]),
            Probe(text: "Take a screenshot with Command Shift Four.", turn: Turn(question: "", scenes: [], allowed: ["narration"]), failing: []),
            Probe(text: "Imagine a loaf of bread.", failing: []),
            Probe(text: "Great question. It is a typo.", failing: ["opener"]),
            Probe(text: "Surely it is a typo.", failing: []),
            Probe(text: "one two three four", turn: Turn(question: "", scenes: [], maxWords: 3), failing: ["length"]),
            Probe(text: "one two three", turn: Turn(question: "", scenes: [], maxWords: 3), failing: []),
            Probe(text: "Use Butter and sugar.", turn: Turn(question: "", scenes: [], mustMention: [["butter", "margarine"], ["sugar"]]), failing: []),
            Probe(text: "Use butter.", turn: Turn(question: "", scenes: [], mustMention: [["butter", "margarine"], ["sugar"]]), failing: ["mustMention"]),
            Probe(text: "It is on your Screen.", turn: Turn(question: "", scenes: [], mustNotMention: ["screen"]), failing: ["mustNotMention"]),
            Probe(text: "Try Biscuit.", turn: Turn(question: "", scenes: [], mustNotMention: ["screen"]), failing: []),
        ]
        var mismatches = 0
        for probe in probes {
            let got = Rule.findings(in: probe.text, for: probe.turn).map(\.rule)
            let ok = got == probe.failing
            print("  \(ok ? "ok  " : "FAIL") \(probe.text.replacingOccurrences(of: "\n", with: " / ")) -> \(got)\(ok ? "" : ", expected \(probe.failing)")")
            if !ok { mismatches += 1 }
        }
        print(mismatches == 0 ? "self-test passed" : "self-test failed: \(mismatches) mismatches")
        return mismatches == 0
    }
}
