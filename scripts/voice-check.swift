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

    static func loop(around box: CGRect) -> [CGPoint] {
        (0...60).map { i in
            let a = -0.5 + Double(i) / 60 * 2.15 * .pi
            let wobble = 1 + 0.04 * sin(Double(i) * 1.7)
            return CGPoint(x: box.midX + (box.width / 2 + 14) * wobble * cos(a), y: box.midY + (box.height / 2 + 10) * wobble * sin(a))
        }
    }

    static func underline(_ x0: CGFloat, _ x1: CGFloat, y: CGFloat) -> [CGPoint] {
        (0...20).map { i in CGPoint(x: x0 + (x1 - x0) * CGFloat(i) / 20, y: y + 2 * sin(CGFloat(i) * 0.9)) }
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
    var ink = Ink()
    let draw: (Canvas) -> Void

    static let display = CGRect(x: 0, y: 0, width: 1710, height: 1112)

    func inked(_ strokes: [[CGPoint]]) -> Scene {
        func global(_ pixel: CGPoint) -> CGPoint {
            CGPoint(x: pixel.x * Scene.display.width / Canvas.width, y: Scene.display.maxY - pixel.y * Scene.display.height / Canvas.height)
        }
        return Scene(name: name + "+ink", cursor: cursor, ink: Ink(strokes.map { Stroke(global($0[0]), $0.dropFirst().map(global)) }), draw: draw)
    }

    var away: Scene {
        var copy = self
        copy.cursor = false
        return copy
    }

    func image(marking: (Canvas) -> Void = { _ in }) -> CGImage {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(Canvas.width), pixelsHigh: Int(Canvas.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        draw(Canvas())
        marking(Canvas())
        NSGraphicsContext.restoreGraphicsState()
        return ink.composited(onto: representation.cgImage!, appKitFrame: Scene.display)
    }

    func screenshot(display: CGDirectDisplayID) -> Screenshot {
        Screenshot(
            encoding: image(), display: display,
            appKitFrame: CGRect(x: 0, y: 0, width: Canvas.width, height: Canvas.height),
            cursor: cursor ? CGPoint(x: Canvas.width / 2, y: Canvas.height / 2) : CGPoint(x: -500, y: -500),
            inked: !ink.isEmpty
        )!
    }

    func png(marking: (Canvas) -> Void = { _ in }) -> Data {
        NSBitmapImageRep(cgImage: image(marking: marking)).representation(using: .png, properties: [:])!
    }
}

extension Scene {
    static let all = [xcodeError, recipe, spreadsheet, wifiSettings, chat, letter, article, finder]

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

    private static let letterLines = [
        "Dear Ms. Alvarez,",
        "",
        "Thank you for meeting with me on Tuesday. I was glad to hear",
        "about the new design team, and I hope to recieve your notes",
        "on the portfolio soon. Please let me know if there is anything",
        "else I can send before the next round.",
        "",
        "Best wishes,",
        "Sam",
    ]

    static func words(_ words: String, after before: String, line: Int, left: CGFloat, top: CGFloat, step: CGFloat, size: CGFloat) -> CGRect {
        let canvas = Canvas()
        return CGRect(
            x: left + canvas.width(of: before, size: size), y: top + CGFloat(line) * step,
            width: canvas.width(of: words, size: size), height: (size * 1.25).rounded()
        )
    }

    static let typo = words("recieve", after: "about the new design team, and I hope to ", line: 3, left: 220, top: 160, step: 38, size: 22)

    static let letter = Scene(name: "letter") { canvas in
        let ink = NSColor(hex: 0x1D1D1F)
        canvas.fill(0, 0, Canvas.width, Canvas.height, NSColor(hex: 0xE5E5E7))
        canvas.menuBar(["TextEdit", "File", "Edit", "Format", "View", "Window", "Help"], background: NSColor(hex: 0xF2F2F2), color: ink)
        canvas.fill(0, 28, Canvas.width, 44, NSColor(hex: 0xE8E8EA))
        canvas.trafficLights(x: 20, y: 43)
        canvas.text("Letter to Ms. Alvarez.rtf", x: Canvas.width / 2, y: 40, size: 16, color: ink, weight: .semibold, anchor: .center)
        canvas.fill(0, 72, Canvas.width, 36, NSColor(hex: 0xF6F6F8))
        canvas.text("Helvetica     Regular     22     B   I   U", x: 24, y: 80, size: 15, color: NSColor(hex: 0x555555))
        canvas.fill(160, 120, 960, 712, .white)
        for (index, line) in letterLines.enumerated() {
            canvas.text(line, x: 220, y: 160 + CGFloat(index) * 38, size: 22, color: ink)
        }
        canvas.squiggle(from: typo.minX, to: typo.maxX, y: typo.maxY - 1, NSColor(hex: 0xFF3B30))
    }

    static let storageSetting = words(
        "Optimize Mac Storage", after: "click your name, then iCloud, and turn on ", line: 2, left: 200, top: 270, step: 34, size: 21
    )

    static let article = Scene(name: "article") { canvas in
        let ink = NSColor(hex: 0x222222)
        let muted = NSColor(hex: 0x666666)
        canvas.fill(0, 0, Canvas.width, Canvas.height, .white)
        canvas.menuBar(["Safari", "File", "Edit", "View", "History", "Bookmarks", "Window", "Help"], background: NSColor(hex: 0xF2F2F2), color: NSColor(hex: 0x1D1D1F))
        canvas.fill(0, 28, Canvas.width, 56, NSColor(hex: 0xE8E8EA))
        canvas.trafficLights(x: 20, y: 49)
        canvas.fill(340, 40, 600, 32, .white, radius: 8)
        canvas.text("support.example/mac-storage", x: 640, y: 47, size: 15, color: muted, anchor: .center)
        canvas.text("Mac Help", x: 200, y: 112, size: 16, color: NSColor(hex: 0x0066CC), weight: .semibold)
        canvas.text("If your Mac is running out of space", x: 200, y: 140, size: 40, color: ink, weight: .bold)
        canvas.text("Store files in iCloud", x: 200, y: 220, size: 26, color: ink, weight: .bold)
        let paragraph = [
            "Your Mac can keep files in iCloud and store only the ones you",
            "used recently on its disk. To set this up, open System Settings,",
            "click your name, then iCloud, and turn on Optimize Mac Storage.",
            "Older files stay in iCloud and download again when you open",
            "them, so they never use space you need.",
        ]
        for (index, line) in paragraph.enumerated() {
            canvas.text(line, x: 200, y: 270 + CGFloat(index) * 34, size: 21, color: ink)
        }
        canvas.text("Find large files", x: 200, y: 470, size: 26, color: ink, weight: .bold)
        canvas.text("Large files you no longer need, like old disk images and", x: 200, y: 520, size: 21, color: ink)
        canvas.text("movies, are the next place to look.", x: 200, y: 554, size: 21, color: ink)
    }

    private enum FinderIcon {
        case folder
        case document(band: UInt32, kind: String)
    }

    private static let finderItems: [(name: String, icon: FinderIcon, column: Int, row: Int)] = [
        ("Invoices", .folder, 0, 0), ("Receipts", .folder, 1, 0), ("Taxes 2026", .folder, 2, 0), ("Projects", .folder, 3, 0),
        ("March invoice.pdf", .document(band: 0xE5484D, kind: "PDF"), 0, 1),
        ("Budget.xlsx", .document(band: 0x1F9D55, kind: "XLSX"), 1, 1),
        ("Notes.txt", .document(band: 0x8E8E93, kind: "TXT"), 2, 1),
    ]

    static func finderItem(column: Int, row: Int) -> CGRect {
        CGRect(x: 390 + CGFloat(column) * 150, y: 142 + CGFloat(row) * 160, width: 120, height: 112)
    }

    static let invoicesFolder = finderItem(column: 0, row: 0)
    static let invoicePDF = finderItem(column: 0, row: 1)
    static let budgetFile = finderItem(column: 1, row: 1)
    static let usbDrive = CGRect(x: 150, y: 380, width: 200, height: 28)

    static let finder = Scene(name: "finder") { canvas in
        let ink = NSColor(hex: 0x1D1D1F)
        let muted = NSColor(hex: 0x8E8E93)
        canvas.gradient(0, 0, Canvas.width, Canvas.height, from: NSColor(hex: 0x2B8A8A), to: NSColor(hex: 0x1F3A68))
        canvas.menuBar(["Finder", "File", "Edit", "View", "Go", "Window", "Help"], background: NSColor(hex: 0xF2F2F2), color: ink)
        canvas.fill(140, 60, 1000, 680, .white, radius: 12)
        canvas.clipped(toRoundedRect: 140, 60, 1000, 680, radius: 12) {
            canvas.fill(140, 60, 220, 680, NSColor(hex: 0xEDEDF0))
        }
        canvas.trafficLights(x: 160, y: 78)
        canvas.text("Documents", x: 760, y: 76, size: 16, color: ink, weight: .semibold, anchor: .center)
        canvas.line(from: CGPoint(x: 360, y: 112), to: CGPoint(x: 1140, y: 112), NSColor(hex: 0xD8D8DC))
        canvas.text("Favorites", x: 160, y: 128, size: 12, color: muted, weight: .semibold)
        let favorites = ["Recents", "Applications", "Desktop", "Documents", "Downloads"]
        for (index, item) in favorites.enumerated() {
            let top = CGFloat(152 + index * 32)
            if item == "Documents" { canvas.fill(150, top - 4, 200, 28, NSColor(hex: 0xD6D6DB), radius: 6) }
            canvas.fill(162, top + 2, 16, 16, NSColor(hex: 0x3D8BFD), radius: 4)
            canvas.text(item, x: 188, y: top, size: 15, color: ink)
        }
        canvas.text("Locations", x: 160, y: 320, size: 12, color: muted, weight: .semibold)
        for (index, item) in ["Macintosh HD", "KINGSTON"].enumerated() {
            let top = CGFloat(352 + index * 32)
            canvas.fill(162, top + 2, 16, 16, NSColor(hex: 0x8E8E93), radius: 3)
            canvas.text(item, x: 188, y: top, size: 15, color: ink)
        }
        canvas.text("\u{23CF}", x: 332, y: 384, size: 14, color: muted, anchor: .center)
        for item in finderItems {
            let slot = finderItem(column: item.column, row: item.row)
            let (centre, top) = (slot.midX, slot.minY + 8)
            let selected = item.name == "March invoice.pdf"
            if selected { canvas.fill(centre - 44, top - 6, 88, 84, NSColor(hex: 0xDCDCE0), radius: 8) }
            switch item.icon {
            case .folder:
                canvas.fill(centre - 36, top + 6, 30, 14, NSColor(hex: 0x4AA3E8), radius: 4)
                canvas.fill(centre - 36, top + 14, 72, 52, NSColor(hex: 0x5AB4F5), radius: 6)
            case .document(let band, let kind):
                canvas.fill(centre - 28, top, 56, 70, .white, radius: 3)
                canvas.outline(centre - 28, top, 56, 70, NSColor(hex: 0xC8C8CC), radius: 3)
                canvas.fill(centre - 28, top + 40, 56, 16, NSColor(hex: band))
                canvas.text(kind, x: centre, y: top + 41, size: 10, color: .white, weight: .bold, anchor: .center)
            }
            let width = canvas.width(of: item.name, size: 14)
            if selected { canvas.fill(centre - width / 2 - 6, top + 78, width + 12, 22, NSColor(hex: 0x0A84FF), radius: 5) }
            canvas.text(item.name, x: centre, y: top + 80, size: 14, color: selected ? .white : ink, anchor: .center)
        }
        canvas.line(from: CGPoint(x: 360, y: 706), to: CGPoint(x: 1140, y: 706), NSColor(hex: 0xD8D8DC))
        canvas.text("7 items, 112 GB available", x: 750, y: 714, size: 13, color: muted, anchor: .center)
    }
}

enum Aim {
    static let slack: CGFloat = 10

    enum Kind: String, CaseIterable {
        case ring, underline, arrow
    }

    case anything
    case nothing
    case at(screen: Int, CGRect, marks: Set<Kind> = [.ring])
    case arrow(from: CGRect, to: CGRect, screen: Int)

    /// Where the mark should land: the thing itself, or the arrow's head.
    var end: (screen: Int, box: CGRect)? {
        switch self {
        case .anything, .nothing: nil
        case .at(let screen, let box, _): (screen, box)
        case .arrow(_, let to, let screen): (screen, to)
        }
    }

    private static func gap(_ box: CGRect, _ x: Int, _ y: Int) -> (dx: CGFloat, dy: CGFloat) {
        (max(box.minX - CGFloat(x), 0, CGFloat(x) - box.maxX), max(box.minY - CGFloat(y), 0, CGFloat(y) - box.maxY))
    }

    func distance(to target: Claude.Target) -> Double? {
        guard let end, case .point(let named, _, let onScreen, _) = target, onScreen == end.screen else { return nil }
        let gap = Aim.gap(end.box, named.centre.x, named.centre.y)
        return Double(hypot(gap.dx, gap.dy))
    }

    /// The IoU of each box Claude drew on the right screen, keyed by the part of the mark it is.
    func ious(_ target: Claude.Target) -> [String: Double] {
        guard let end, case .point(let named, _, let onScreen, let mark) = target else { return [:] }
        var found: [String: Double] = [:]
        if onScreen == end.screen, !named.isPoint { found[mark.kind == .arrow ? "arrow end" : mark.kind.rawValue] = Aim.iou(Aim.rect(named), end.box) }
        if case .arrow(let from, _, let screen) = self, case .arrow(let start, _, let startScreen) = mark, startScreen == screen, !start.isPoint {
            found["arrow start"] = Aim.iou(Aim.rect(start), from)
        }
        return found
    }

    func wrongMark(_ target: Claude.Target) -> String? {
        guard case .point(_, _, _, let mark) = target else { return nil }
        let wanted: Set<Kind>
        switch self {
        case .anything, .nothing: return nil
        case .at(_, _, let marks): wanted = marks
        case .arrow: wanted = [.arrow]
        }
        guard !wanted.contains(mark.kind) else { return nil }
        return "\(mark.kind.rawValue) but expected \(Kind.allCases.filter(wanted.contains).map(\.rawValue).joined(separator: " or "))"
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let shared = overlap.width * overlap.height
        return Double(shared / (a.width * a.height + b.width * b.height - shared))
    }

    static func rect(_ box: Screenshot.Box) -> CGRect {
        CGRect(x: box.x1, y: box.y1, width: box.x2 - box.x1, height: box.y2 - box.y1)
    }

    static func spot(_ box: Screenshot.Box) -> String {
        box.isPoint ? "\(box.x1),\(box.y1)" : "box \(box.x1),\(box.y1),\(box.x2),\(box.y2) centred on \(box.centre.x),\(box.centre.y)"
    }

    private static func miss(_ named: Screenshot.Box, on onScreen: Int, from box: CGRect, on screen: Int) -> String? {
        guard onScreen == screen else { return "screen\(onScreen) but expected screen\(screen)" }
        let gap = Aim.gap(box, named.centre.x, named.centre.y)
        guard gap.dx > Aim.slack || gap.dy > Aim.slack else { return nil }
        return "screen\(screen) \(Aim.spot(named)) is \(Int(hypot(gap.dx, gap.dy).rounded())) px from the box"
    }

    /// Where the mark landed. The `mark` rule judges its kind, so a ring at an arrow's head passes here.
    func offense(_ target: Claude.Target) -> String? {
        switch (self, target) {
        case (.anything, _): return nil
        case (.nothing, .none): return nil
        case (.nothing, .point(let named, _, let screen, _)): return "pointed at screen\(screen) \(Aim.spot(named)) but expected none"
        case (.at(let screen, _, _), .none), (.arrow(_, _, let screen), .none): return "none but expected a point on screen\(screen)"
        case (.at(let screen, let box, _), .point(let named, _, let onScreen, _)):
            return Aim.miss(named, on: onScreen, from: box, on: screen)
        case (.arrow(let from, let to, let screen), .point(let named, _, let onScreen, let mark)):
            if let miss = Aim.miss(named, on: onScreen, from: to, on: screen) { return "end " + miss }
            guard case .arrow(let start, _, let startScreen) = mark else { return nil }
            return Aim.miss(start, on: startScreen, from: from, on: screen).map { "start " + $0 }
        }
    }
}

extension Claude.Target.Mark {
    var kind: Aim.Kind {
        switch self {
        case .ring: .ring
        case .underline: .underline
        case .arrow: .arrow
        }
    }
}

struct Turn {
    let question: String
    let scenes: [Scene]
    var aim = Aim.anything
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

struct Answered {
    let said: Claude.Said
    let turn: Turn
}

struct Rule {
    let name: String
    let offense: (Answered) -> String?

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
        Rule(name: name) { match(pattern, in: $0.said.spoken) }
    }

    static let all: [Rule] = [
        pattern("markdown", #"[*`#|]|__|\[[^\]]*\]\([^)]*\)"#),
        pattern("list", #"(?m)^[ \t]*(?:[-\#u{2022}]|\d+[.)])[ \t]"#),
        Rule(name: "paragraphs") { reply in
            let lines = reply.said.spoken.split(separator: "\n").filter { !$0.allSatisfy(\.isWhitespace) }
            return lines.count > 2 ? "\(lines.count) lines" : nil
        },
        pattern(
            "abbreviation",
            #"\be\.g\.|\bi\.e\.|\betc\b|\bvs\b|\bapprox\b|\bw/|&|\#u{2192}|~|[\#u{2318}\#u{2325}\#u{21E7}\#u{2303}]|\b(?:cmd|ctrl|opt)\b|\d ?(?:km|kg|lbs?|oz|tsp|tbsp|mins?|hrs?|secs?|ms|mph|ft|cm|mm)\b|\d/\d|\#u{00B0}"#
        ),
        pattern("link", #"http|www\.|~/|/Users/"#),
        pattern("code", #"\w\(|[{}=]"#),
        Rule(name: "emoji") { reply in
            reply.said.spoken.unicodeScalars.first(where: \.properties.isEmojiPresentation).map { String($0) }
        },
        pattern("narration", #"\bscreenshots?\b|\bimages?\b|as an ai|language model"#),
        pattern("pointer", #"\bpoint(?:ing|ed)? (?:at|to)\b|\bpointer\b"#),
        pattern("opener", #"^(?:great question|sure|certainly|of course|absolutely|happy to)\b"#),
        Rule(name: "length") { reply in
            let count = words(in: reply.said.spoken)
            return count > reply.turn.maxWords ? "\(count) words, limit \(reply.turn.maxWords)" : nil
        },
        Rule(name: "mustMention") { reply in
            let lowered = reply.said.spoken.lowercased()
            let missing = reply.turn.mustMention.filter { group in !group.contains { lowered.contains($0.lowercased()) } }
            return missing.isEmpty ? nil : "missing " + missing.map { $0.joined(separator: " / ") }.joined(separator: "; ")
        },
        Rule(name: "mustNotMention") { reply in
            let lowered = reply.said.spoken.lowercased()
            let found = reply.turn.mustNotMention.filter { lowered.contains($0.lowercased()) }
            return found.isEmpty ? nil : "found " + found.joined(separator: ", ")
        },
        Rule(name: "tag") { reply in
            reply.said.target == nil ? (reply.said.tag ?? String(reply.said.spoken.suffix(40))).replacingOccurrences(of: "\n", with: " / ") : nil
        },
        Rule(name: "aim") { reply in
            reply.said.target.flatMap { reply.turn.aim.offense($0) }
        },
        Rule(name: "mark") { reply in
            reply.said.target.flatMap { reply.turn.aim.wrongMark($0) }
        },
    ]

    static func findings(in reply: Answered) -> [Finding] {
        all.compactMap { rule in
            guard !reply.turn.allowed.contains(rule.name), let snippet = rule.offense(reply) else { return nil }
            return Finding(rule: rule.name, snippet: snippet)
        }
    }
}

extension Case {
    private static let wifiSwitch = CGRect(x: 990, y: 184, width: 52, height: 30)
    private static let notifications = CGRect(x: 204, y: 332, width: 242, height: 40)
    private static let thirdBubble = CGRect(x: 372, y: 312, width: Canvas().width(of: "Can you send me the slides before 3pm?", size: 20) + 36, height: 48)
    private static let buildTypo = [["reponse", "response", "typo", "misspel", "spelled"]]
    private static let errorMessage: CGRect = {
        let canvas = Canvas()
        let code = ["        print(", "reponse", ".statusCode)"].reduce(90) { $0 + canvas.width(of: $1, size: 18, mono: true) }
        return CGRect(x: code + 36, y: 329, width: canvas.width(of: "Cannot find 'reponse' in scope", size: 15) + 28, height: 26)
    }()

    static let all: [Case] = [
        Case(name: "error", turns: [Turn(question: "Why won't this build?", scenes: [.xcodeError], mustMention: buildTypo)]),
        Case(name: "misheard", turns: [Turn(question: "Why won't this bill?", scenes: [.xcodeError], mustMention: buildTypo)]),
        Case(name: "irrelevant", turns: [Turn(
            question: "What's a good name for a golden retriever puppy?", scenes: [.spreadsheet],
            aim: .nothing, mustNotMention: ["screen", "spreadsheet", "budget", "revenue"]
        )]),
        Case(name: "shortcut", turns: [Turn(
            question: "How do I take a screenshot of just part of my screen?", scenes: [.wifiSettings],
            aim: .nothing, mustMention: [["command"], ["shift"], ["four", "4"]], allowed: ["narration"]
        )]),
        Case(name: "steps", turns: [Turn(question: "How do I set up an SSH key for GitHub?", scenes: [.xcodeError], aim: .nothing, maxWords: 90)]),
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
            aim: .nothing, mustMention: [["don't see", "can't see", "not seeing", "isn't on", "not on your screen", "don't have", "can't find", "not showing", "no message"]],
            mustNotMention: ["slides"]
        )]),
        Case(name: "reply", turns: [Turn(question: "What should I tell her?", scenes: [.chat], mustMention: [["slides"]])]),
        Case(name: "followUp", turns: [
            Turn(question: "Why won't this build?", scenes: [.xcodeError]),
            Turn(question: "Okay, how do I fix it?", scenes: [.xcodeError], mustMention: [["response"]]),
        ]),
        Case(name: "code", turns: [Turn(
            question: "How do I reverse a string in Swift?", scenes: [.spreadsheet],
            aim: .nothing, mustMention: [["reversed"]], mustNotMention: ["spreadsheet", "screen"]
        )]),
        Case(name: "wifi", turns: [Turn(question: "Why can't I get online?", scenes: [.wifiSettings], mustMention: [["wi-fi", "wifi", "wi fi"]])]),
        Case(name: "wifiToggle", turns: [Turn(question: "Where do I turn Wi-Fi on?", scenes: [.wifiSettings], aim: .at(screen: 1, wifiSwitch))]),
        Case(name: "settingsTour", turns: [
            Turn(question: "Where do I turn Wi-Fi on?", scenes: [.wifiSettings], aim: .at(screen: 1, wifiSwitch)),
            Turn(question: "And where's Bluetooth?", scenes: [.wifiSettings], aim: .at(screen: 1, CGRect(x: 204, y: 240, width: 242, height: 40))),
            Turn(question: "What about notifications?", scenes: [.wifiSettings], aim: .at(screen: 1, notifications)),
            Turn(question: "What's a good name for a golden retriever puppy?", scenes: [.wifiSettings], aim: .nothing, mustNotMention: ["screen", "wi-fi", "bluetooth"]),
            Turn(question: "Okay, and where's Sound?", scenes: [.wifiSettings], aim: .at(screen: 1, CGRect(x: 204, y: 378, width: 242, height: 40))),
            Turn(question: "How many ounces are in a cup?", scenes: [.wifiSettings], aim: .nothing, mustNotMention: ["screen", "sound", "settings"]),
        ]),
        Case(name: "bluetooth", turns: [Turn(
            question: "Where are my Bluetooth settings?", scenes: [.wifiSettings],
            aim: .at(screen: 1, CGRect(x: 204, y: 240, width: 242, height: 40))
        )]),
        Case(name: "totalCell", turns: [Turn(
            question: "Which cell has the total revenue?", scenes: [.spreadsheet],
            aim: .at(screen: 1, CGRect(x: 320, y: 304, width: 220, height: 40)), mustMention: [["B5", "B 5", "b five"]]
        )]),
        Case(name: "errorLine", turns: [Turn(
            question: "Where's the error?", scenes: [.xcodeError],
            aim: .at(screen: 1, CGRect(x: 0, y: 322, width: 1280, height: 38), marks: [.ring, .underline])
        )]),
        Case(name: "otherScreen", turns: [Turn(
            question: "How do I turn my Wi-Fi back on?", scenes: [.chat, Scene.wifiSettings.away], aim: .at(screen: 2, wifiSwitch)
        )]),
        Case(name: "otherMessage", turns: [Turn(
            question: "Where's Priya's message about the slides?", scenes: [.wifiSettings, Scene.chat.away], aim: .at(screen: 2, thirdBubble, marks: [.ring, .underline])
        )]),
        Case(name: "inkCell", turns: [Turn(
            question: "What's this number?", scenes: [Scene.spreadsheet.inked([Canvas.loop(around: CGRect(x: 640, y: 228, width: 110, height: 32))])],
            aim: .at(screen: 1, CGRect(x: 540, y: 224, width: 220, height: 40)), mustMention: [["3,100", "3100", "three thousand one hundred", "thirty-one hundred", "thirty one hundred"]]
        )]),
        Case(name: "inkChat", turns: [Turn(
            question: "What did she say?", scenes: [Scene.chat.inked([Canvas.loop(around: CGRect(x: 24, y: 372, width: 240, height: 50))])],
            aim: .at(screen: 1, CGRect(x: 10, y: 362, width: 320, height: 70), marks: [.ring, .underline]), mustMention: [["call"]], mustNotMention: ["slides"]
        )]),
        Case(name: "inkUnderline", turns: [Turn(
            question: "What's this for?", scenes: [Scene.wifiSettings.inked([Canvas.underline(246, 362, y: 504)])],
            aim: .at(screen: 1, CGRect(x: 204, y: 470, width: 242, height: 40), marks: [.ring, .underline]), mustMention: [["screen time"]]
        )]),
        Case(name: "inkIrrelevant", turns: [Turn(
            question: "How many ounces are in a cup?", scenes: [Scene.spreadsheet.inked([Canvas.loop(around: CGRect(x: 640, y: 228, width: 110, height: 32))])],
            aim: .nothing, mustNotMention: ["circle", "red", "drew", "marked", "spreadsheet", "3,100"]
        )]),
        Case(name: "spelling", turns: [Turn(
            question: "Which word did I spell wrong?", scenes: [.letter],
            aim: .at(screen: 1, Scene.typo, marks: [.underline]), mustMention: [["receive", "recieve"]]
        )]),
        Case(name: "articleSetting", turns: [Turn(
            question: "What setting does this tell me to turn on?", scenes: [.article],
            aim: .at(screen: 1, Scene.storageSetting, marks: [.underline]), mustMention: [["optimize mac storage"]]
        )]),
        Case(name: "errorMessage", turns: [Turn(
            question: "What does the error message say?", scenes: [.xcodeError],
            aim: .at(screen: 1, errorMessage, marks: [.underline]), mustMention: [["find"]]
        )]),
        Case(name: "moveFile", turns: [Turn(
            question: "How do I put this PDF in the Invoices folder?", scenes: [.finder],
            aim: .arrow(from: Scene.invoicePDF, to: Scene.invoicesFolder, screen: 1)
        )]),
        Case(name: "copyToDrive", turns: [Turn(
            question: "How do I copy the budget spreadsheet onto my USB stick?", scenes: [.finder],
            aim: .arrow(from: Scene.budgetFile, to: Scene.usbDrive, screen: 1)
        )]),
        Case(name: "findDrive", turns: [Turn(
            question: "Where's my USB stick?", scenes: [.finder], aim: .at(screen: 1, Scene.usbDrive), mustMention: [["kingston"]]
        )]),
    ]
}

struct Options {
    var runs = 1
    var only: Set<String>?
    var scenes: String?
    var out: String?
    var points: String?
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
            case "--points": points = value(argument)
            case "--self-test": selfTest = true
            default: Options.usage("unknown argument \(argument)")
            }
        }
    }

    static func usage(_ problem: String) -> Never {
        print("\(problem)\nusage: voice-check [--runs N] [--only name,name] [--scenes DIR] [--out FILE] [--points DIR] [--self-test]")
        exit(2)
    }
}

struct Tally {
    var answers = 0
    var failed = 0
    var byRule: [String: Int] = [:]
    var aimed = 0
    var inside = 0
    var misses: [Double] = []
    var ious: [String: [Double]] = [:]
    var cases: [(name: String, passed: Int, runs: Int)] = []
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
        let tally = await run(cases, runs: options.runs, key: key, outPath: options.out, pointsPath: options.points)
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

    static func marked(_ scene: Scene, expected: [CGRect], target: Claude.Target) -> Data {
        scene.png { canvas in
            for box in expected {
                canvas.outline(box.minX, box.minY, box.width, box.height, NSColor(hex: 0x00B050), thickness: 3)
            }
            guard case .point(let named, _, let screen, let mark) = target else { return }
            let red = NSColor(hex: 0xFF0000)
            if !named.isPoint {
                let drawn = Aim.rect(named)
                canvas.outline(drawn.minX, drawn.minY, drawn.width, drawn.height, red, thickness: 2)
            }
            let center = CGPoint(x: named.centre.x, y: named.centre.y)
            canvas.line(from: CGPoint(x: center.x - 16, y: center.y), to: CGPoint(x: center.x + 16, y: center.y), red, thickness: 2)
            canvas.line(from: CGPoint(x: center.x, y: center.y - 16), to: CGPoint(x: center.x, y: center.y + 16), red, thickness: 2)
            canvas.outline(center.x - 9, center.y - 9, 18, 18, red, radius: 9, thickness: 2)
            switch mark {
            case .underline:
                canvas.line(from: CGPoint(x: named.x1, y: named.y2 + 4), to: CGPoint(x: named.x2, y: named.y2 + 4), red, thickness: 4)
            case .arrow(let from, _, let start) where start == screen:
                let drawn = Aim.rect(from)
                canvas.outline(drawn.minX, drawn.minY, drawn.width, drawn.height, red, thickness: 2)
                canvas.line(from: CGPoint(x: from.centre.x, y: from.centre.y), to: center, red, thickness: 2)
            case .ring, .arrow: break
            }
        }
    }

    static func writePoint(_ target: Claude.Target, for turn: Turn, to path: String) {
        guard case .point(_, _, let screen, _) = target, turn.scenes.indices.contains(screen - 1) else { return }
        let expected: [CGRect] = switch turn.aim {
        case .at(screen, let box, _): [box]
        case .arrow(let from, let to, screen): [from, to]
        default: []
        }
        do {
            try marked(turn.scenes[screen - 1], expected: expected, target: target).write(to: URL(fileURLWithPath: path))
        } catch {
            print("FAIL writing \(path): \(error.localizedDescription)")
        }
    }

    static func run(_ cases: [Case], runs: Int, key: String, outPath: String?, pointsPath: String?) async -> Tally {
        var tally = Tally()
        if let pointsPath { try? FileManager.default.createDirectory(atPath: pointsPath, withIntermediateDirectories: true) }
        var out: FileHandle?
        if let outPath {
            FileManager.default.createFile(atPath: outPath, contents: nil)
            out = FileHandle(forWritingAtPath: outPath)
        }
        var utterance = 0
        for current in cases {
            var passed = 0
            for run in 1...runs {
                var clean = true
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
                    var findings: [Finding] = []
                    var reply: Answered?
                    do throws(Claude.Failure) {
                        let answered = Answered(said: try await conversation.answer(question, utterance: utterance) { _ in
                            if first == 0 { first = elapsed() }
                        }, turn: turn)
                        reply = answered
                        findings = Rule.findings(in: answered)
                    } catch {
                        findings = [Finding(rule: "api", snippet: error.logFields)]
                    }
                    let total = elapsed()
                    let said = reply?.said
                    let spoken = said?.spoken ?? ""
                    let words = Rule.words(in: spoken)
                    if !spoken.isEmpty {
                        print(spoken.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { "  \($0 == 0 ? "A:" : "  ") \($1)" }.joined(separator: "\n"))
                    }
                    let target = said?.target
                    if let said {
                        switch target {
                        case nil: print("  T: missing" + (said.tag.map { " (tag \($0.debugDescription))" } ?? ""))
                        case .some(.none): print("  T: none")
                        case .some(.point(let named, let label, let screen, let mark)):
                            let start = switch mark {
                            case .arrow(let from, let fromLabel, let startScreen): " from screen\(startScreen) \(Aim.spot(from)) \"\(fromLabel)\""
                            case .ring, .underline: ""
                            }
                            print("  T: \(mark.kind.rawValue) screen\(screen) \(Aim.spot(named)) \"\(label)\"\(start)")
                        }
                    }
                    print("  \(words) words, first text \(first) ms, total \(total) ms")
                    if findings.isEmpty {
                        print("  ok")
                    } else {
                        for finding in findings { print("  FAIL \(finding.rule): \(finding.snippet)") }
                    }
                    tally.answers += 1
                    if !findings.isEmpty { tally.failed += 1 }
                    if !findings.isEmpty { clean = false }
                    for finding in findings { tally.byRule[finding.rule, default: 0] += 1 }
                    let ious = target.map(turn.aim.ious) ?? [:]
                    if reply != nil, turn.aim.end != nil {
                        tally.aimed += 1
                        for (part, overlap) in ious { tally.ious[part, default: []].append(overlap) }
                        if !findings.contains(where: { $0.rule == "tag" || $0.rule == "aim" }) {
                            tally.inside += 1
                        } else if let target, let miss = turn.aim.distance(to: target) {
                            tally.misses.append(miss)
                        }
                    }
                    if let pointsPath, let target {
                        writePoint(target, for: turn, to: "\(pointsPath)/\(current.name)-run\(run)-turn\(index + 1).png")
                    }
                    var record: [String: Any] = [
                        "case": current.name, "run": run, "turn": index + 1, "question": turn.question, "answer": spoken, "tag": said?.tag ?? NSNull(),
                        "words": words, "firstMs": first, "totalMs": total, "target": targetRecord(target),
                        "failures": findings.map { "\($0.rule): \($0.snippet)" },
                    ]
                    if let end = turn.aim.end {
                        var expected = boxRecord(end.box, screen: end.screen)
                        switch turn.aim {
                        case .at(_, _, let marks): expected["marks"] = Aim.Kind.allCases.filter(marks.contains).map(\.rawValue)
                        case .arrow(let from, _, let screen): (expected["marks"], expected["from"]) = (["arrow"], boxRecord(from, screen: screen))
                        case .anything, .nothing: break
                        }
                        record["expected"] = expected
                        record["ious"] = ious
                        if let overlap = ious["ring"] ?? ious["underline"] ?? ious["arrow end"] { record["iou"] = overlap }
                    }
                    if let line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) {
                        out?.write(line + Data("\n".utf8))
                    }
                }
                if clean { passed += 1 }
            }
            tally.cases.append((current.name, passed, runs))
        }
        try? out?.close()
        return tally
    }

    static func targetRecord(_ target: Claude.Target?) -> Any {
        switch target {
        case nil: return NSNull()
        case .some(.none): return "none"
        case .some(.point(let named, let label, let screen, let mark)):
            var record = spotRecord(named, label: label, screen: screen)
            record["mark"] = mark.kind.rawValue
            if case .arrow(let from, let fromLabel, let start) = mark { record["from"] = spotRecord(from, label: fromLabel, screen: start) }
            return record
        }
    }

    static func spotRecord(_ box: Screenshot.Box, label: String, screen: Int) -> [String: Any] {
        box.isPoint
            ? ["screen": screen, "x": box.x1, "y": box.y1, "label": label]
            : ["screen": screen, "x1": box.x1, "y1": box.y1, "x2": box.x2, "y2": box.y2, "label": label]
    }

    static func boxRecord(_ box: CGRect, screen: Int) -> [String: Any] {
        ["screen": screen, "x1": Int(box.minX), "y1": Int(box.minY), "x2": Int(box.maxX), "y2": Int(box.maxY)]
    }

    static func printSummary(_ tally: Tally) {
        print("summary")
        for name in Rule.all.map(\.name) + ["api"] {
            print("  \(name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(tally.byRule[name, default: 0])")
        }
        print("  pointing        \(tally.inside) of \(tally.aimed) inside the box, median miss \(median(tally.misses).map { "\(Int($0.rounded())) px" } ?? "none")")
        for part in ["ring", "underline", "arrow start", "arrow end"] {
            let ious = tally.ious[part, default: []]
            print("  \("\(part) IoU".padding(toLength: 15, withPad: " ", startingAt: 0)) \(ious.count) boxes on the right screen, median \(median(ious).map { String(format: "%.2f", $0) } ?? "none")")
        }
        print("  failing answers \(tally.failed) of \(tally.answers)")
        print("cases")
        for row in tally.cases {
            print("  \(row.name.padding(toLength: 15, withPad: " ", startingAt: 0)) \(row.passed) of \(row.runs) runs passed")
        }
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }

    static func selfTest() -> Bool {
        struct Probe {
            let text: String
            var turn = Turn(question: "", scenes: [])
            var tagged = true
            let failing: [String]
            var detail: String?
        }
        let switchAim = Aim.at(screen: 1, CGRect(x: 990, y: 184, width: 52, height: 30))
        let aimTurn = Turn(question: "", scenes: [], aim: switchAim)
        let nothingTurn = Turn(question: "", scenes: [], aim: .nothing)
        let underlineTurn = Turn(question: "", scenes: [], aim: .at(screen: 1, CGRect(x: 400, y: 300, width: 120, height: 28), marks: [.underline]))
        let eitherTurn = Turn(question: "", scenes: [], aim: .at(screen: 1, CGRect(x: 400, y: 300, width: 120, height: 28), marks: [.ring, .underline]))
        let arrowAim = Aim.arrow(from: CGRect(x: 100, y: 100, width: 100, height: 100), to: CGRect(x: 600, y: 400, width: 100, height: 100), screen: 1)
        let arrowTurn = Turn(question: "", scenes: [], aim: arrowAim)
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
            Probe(text: "It isn't about your screen, so I'm not pointing at anything.", failing: ["pointer"]),
            Probe(text: "The pointer is on the switch.", failing: ["pointer"]),
            Probe(text: "That point is fair, and it points out a typo.", failing: []),
            Probe(text: "Great question. It is a typo.", failing: ["opener"]),
            Probe(text: "Surely it is a typo.", failing: []),
            Probe(text: "one two three four", turn: Turn(question: "", scenes: [], maxWords: 3), failing: ["length"]),
            Probe(text: "one two three", turn: Turn(question: "", scenes: [], maxWords: 3), failing: []),
            Probe(text: "Use Butter and sugar.", turn: Turn(question: "", scenes: [], mustMention: [["butter", "margarine"], ["sugar"]]), failing: []),
            Probe(text: "Use butter.", turn: Turn(question: "", scenes: [], mustMention: [["butter", "margarine"], ["sugar"]]), failing: ["mustMention"]),
            Probe(text: "It is on your Screen.", turn: Turn(question: "", scenes: [], mustNotMention: ["screen"]), failing: ["mustNotMention"]),
            Probe(text: "Try Biscuit.", turn: Turn(question: "", scenes: [], mustNotMention: ["screen"]), failing: []),
            Probe(text: "Flip the switch. [POINT:1042,199:Wi-Fi switch]", tagged: false, failing: []),
            Probe(text: "Flip the switch. [POINT:1042,199:Wi-Fi switch]", turn: aimTurn, tagged: false, failing: []),
            Probe(text: "Flip the switch. [POINT:1052,224:Wi-Fi switch:screen1]", turn: aimTurn, tagged: false, failing: []),
            Probe(text: "Flip the switch. [POINT:1053,199:Wi-Fi switch:screen1]", turn: aimTurn, tagged: false, failing: ["aim"], detail: "screen1 1053,199 is 11 px from the box"),
            Probe(text: "Flip the switch. [POINT:1000,190:Wi-Fi switch:screen2]", turn: aimTurn, tagged: false, failing: ["aim"], detail: "screen2 but expected screen1"),
            Probe(text: "Flip the switch. [POINT:none]", turn: aimTurn, tagged: false, failing: ["aim"], detail: "none but expected a point on screen1"),
            Probe(text: "Flip the switch. [POINT:1000,190:Wi-Fi switch]", turn: nothingTurn, tagged: false, failing: ["aim"], detail: "pointed at screen1 1000,190 but expected none"),
            Probe(text: "Flip the switch. [POINT:none]", turn: nothingTurn, tagged: false, failing: []),
            Probe(text: "Flip the switch.", tagged: false, failing: ["tag"], detail: "Flip the switch."),
            Probe(text: "Flip the switch. [POINT:1,2:x] and more", turn: aimTurn, tagged: false, failing: ["tag"], detail: "Flip the switch. [POINT:1,2:x] and more"),
            Probe(text: "Flip the switch. [POINT:990,184,1042,214:Wi-Fi switch:screen1]", turn: aimTurn, tagged: false, failing: []),
            Probe(text: "Flip the switch. [POINT:1000,190,1100,230:Wi-Fi switch:screen1]", turn: aimTurn, tagged: false, failing: []),
            Probe(text: "Flip the switch. [POINT:1100,190,1200,230:Wi-Fi switch:screen1]", turn: aimTurn, tagged: false, failing: ["aim"],
                  detail: "screen1 box 1100,190,1200,230 centred on 1150,210 is 108 px from the box"),
            Probe(text: "Flip the switch. [POINT:990,184,1042,214:Wi-Fi switch:screen1]", turn: nothingTurn, tagged: false, failing: ["aim"],
                  detail: "pointed at screen1 box 990,184,1042,214 centred on 1016,199 but expected none"),
            Probe(text: "Flip the switch. [POINT:1,2,3,4:x] and more", turn: aimTurn, tagged: false, failing: ["tag"]),
            Probe(text: "Flip it. [POINT:12,40]", tagged: false, failing: ["tag"], detail: "[POINT:12,40]"),
            Probe(text: "Use `reversed()` [POINT:none]", tagged: false, failing: ["markdown", "code"]),
            Probe(text: "Click [POINT:1,2:a](b) here.", tagged: false, failing: ["markdown", "tag"], detail: "Click [POINT:1,2:a](b) here."),
            Probe(text: "Fix it. [UNDERLINE:400,300,520,328:word:screen1]", turn: underlineTurn, tagged: false, failing: []),
            Probe(text: "Fix it. [POINT:400,300,520,328:word:screen1]", turn: underlineTurn, tagged: false, failing: ["mark"], detail: "ring but expected underline"),
            Probe(text: "Fix it. [UNDERLINE:700,300,820,328:word:screen1]", turn: underlineTurn, tagged: false, failing: ["aim"],
                  detail: "screen1 box 700,300,820,328 centred on 760,314 is 240 px from the box"),
            Probe(text: "Fix it. [POINT:400,300,520,328:word:screen1]", turn: eitherTurn, tagged: false, failing: []),
            Probe(text: "Fix it. [UNDERLINE:400,300,520,328:word:screen1]", turn: eitherTurn, tagged: false, failing: []),
            Probe(text: "Fix it. [ARROW:1,2:a:400,300,520,328:word:screen1]", turn: eitherTurn, tagged: false, failing: ["mark"], detail: "arrow but expected ring or underline"),
            Probe(text: "Fix it. [UNDERLINE:1,2,3,4:x:screen1]", turn: nothingTurn, tagged: false, failing: ["aim"],
                  detail: "pointed at screen1 box 1,2,3,4 centred on 2,3 but expected none"),
            Probe(text: "Drag it. [ARROW:110,110,190,190:file:screen1:610,410,690,490:folder:screen1]", turn: arrowTurn, tagged: false, failing: []),
            Probe(text: "Drag it. [POINT:610,410,690,490:folder:screen1]", turn: arrowTurn, tagged: false, failing: ["mark"], detail: "ring but expected arrow"),
            Probe(text: "Drag it. [ARROW:610,410,690,490:folder:screen1:110,110,190,190:file:screen1]", turn: arrowTurn, tagged: false, failing: ["aim"],
                  detail: "end screen1 box 110,110,190,190 centred on 150,150 is 515 px from the box"),
            Probe(text: "Drag it. [ARROW:300,300,340,340:file:screen1:610,410,690,490:folder:screen1]", turn: arrowTurn, tagged: false, failing: ["aim"],
                  detail: "start screen1 box 300,300,340,340 centred on 320,320 is 170 px from the box"),
            Probe(text: "Drag it. [ARROW:110,110,190,190:file:screen2:610,410,690,490:folder:screen1]", turn: arrowTurn, tagged: false, failing: ["aim"],
                  detail: "start screen2 but expected screen1"),
            Probe(text: "Drag it. [POINT:none]", turn: arrowTurn, tagged: false, failing: ["aim"], detail: "none but expected a point on screen1"),
        ]
        var mismatches = 0
        let png = marked(.wifiSettings, expected: [CGRect(x: 990, y: 184, width: 52, height: 30)], target: .point(.init(x: 700, y: 600), label: "x", screen: 1, mark: .ring))
        let pixel = { (x: Int, y: Int) in NSBitmapImageRep(data: png)?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        let red = pixel(712, 600), box = pixel(1000, 184), bare = pixel(720, 650)
        let drawn = (red?.redComponent ?? 0) > 0.9 && (red?.greenComponent ?? 1) < 0.2
            && (box?.greenComponent ?? 0) > 0.6 && (box?.redComponent ?? 1) < 0.2
            && (bare?.redComponent ?? 0) > 0.9 && (bare?.greenComponent ?? 0) > 0.9
        print("  \(drawn ? "ok  " : "FAIL") marked png has a red crosshair at 700,600 and a green box at 990,184")
        if !drawn { mismatches += 1 }
        let inked = NSBitmapImageRep(cgImage: Scene.spreadsheet.inked([[CGPoint(x: 100, y: 700), CGPoint(x: 300, y: 700)]]).image())
        let ink = { (x: Int, y: Int) in inked.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        let line = [ink(200, 699), ink(200, 700)], edges = [ink(200, 698), ink(200, 701)], clear = [ink(200, 696), ink(200, 703)]
        let isRed = { (colour: NSColor?) in (colour?.redComponent ?? 0) > 0.95 && (colour?.greenComponent ?? 1) < 0.25 }
        let threePixels = line.allSatisfy(isRed) && edges.allSatisfy { !isRed($0) && ($0?.greenComponent ?? 1) < 0.85 }
            && clear.allSatisfy { ($0?.greenComponent ?? 0) > 0.85 }
        print("  \(threePixels ? "ok  " : "FAIL") an inked scene has a 3 px red line from 100,700 to 300,700: rows 699 and 700 red, 698 and 701 half, 696 and 703 clear")
        if !threePixels { mismatches += 1 }
        let marks = "The user drew the red marks on this screen"
        let labels = [Scene.spreadsheet.inked([[CGPoint(x: 100, y: 700)]]), Scene.spreadsheet].map { $0.screenshot(display: 1).label(number: 1, of: 1) }
        let labelled = labels[0].contains(marks) && !labels[1].contains(marks)
        print("  \(labelled ? "ok  " : "FAIL") an inked scene's label says the user drew the red marks, a plain scene's does not")
        if !labelled { mismatches += 1 }
        let boxPng = marked(.wifiSettings, expected: [], target: .point(.init(x1: 600, y1: 500, x2: 800, y2: 700), label: "x", screen: 1, mark: .ring))
        let boxPixel = { (x: Int, y: Int) in NSBitmapImageRep(data: boxPng)?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        let boxEdge = boxPixel(600, 600), boxCross = boxPixel(712, 600), boxInside = boxPixel(650, 650)
        let outlined = [boxEdge, boxCross].allSatisfy { ($0?.redComponent ?? 0) > 0.9 && ($0?.greenComponent ?? 1) < 0.2 }
            && (boxInside?.greenComponent ?? 1) > 0.2
        print("  \(outlined ? "ok  " : "FAIL") a boxed target draws a red outline at 600,500 to 800,700 and a crosshair on its centre 700,600")
        if !outlined { mismatches += 1 }
        let boxSaid = Claude.Said("Flip the switch. [POINT:990,184,1042,214:Wi-Fi switch:screen1]")
        let boxTarget = Claude.Target.point(.init(x1: 990, y1: 184, x2: 1042, y2: 214), label: "Wi-Fi switch", screen: 1, mark: .ring)
        let boxOK = boxSaid.spoken == "Flip the switch." && boxSaid.target == boxTarget
        print("  \(boxOK ? "ok  " : "FAIL") Said strips a box tag and parses its box")
        if !boxOK { mismatches += 1 }
        let halves = Aim.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 0, width: 10, height: 10))
        let exact = switchAim.ious(boxTarget)
        let elsewhere = Aim.at(screen: 2, CGRect(x: 990, y: 184, width: 52, height: 30)).ious(boxTarget)
        let iouOK = abs(halves - 1.0 / 3.0) < 1e-9 && exact == ["ring": 1] && elsewhere.isEmpty
            && switchAim.ious(.point(.init(x: 1016, y: 199), label: "x", screen: 1, mark: .ring)).isEmpty
        print("  \(iouOK ? "ok  " : "FAIL") IoU is 1/3 for half-overlapping squares, 1 for the switch's own box, none on another screen or for a point")
        if !iouOK { mismatches += 1 }
        let arrowIous = Claude.Said("Drag it. [ARROW:100,100,200,200:file:screen1:600,400,700,450:folder:screen1]").target.map(arrowAim.ious)
        let ringIous = Claude.Said("Drag it. [POINT:600,400,700,500:folder:screen1]").target.map(arrowAim.ious)
        let partsOK = arrowIous == ["arrow start": 1, "arrow end": 0.5] && ringIous == ["ring": 1]
        print("  \(partsOK ? "ok  " : "FAIL") an arrow scores its start and end apart, a ring at the arrow's end scores as a ring, got \(String(describing: arrowIous)), \(String(describing: ringIous))")
        if !partsOK { mismatches += 1 }
        let isRedAt = { (png: Data, x: Int, y: Int) in
            let colour = NSBitmapImageRep(data: png)?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            return (colour?.redComponent ?? 0) > 0.9 && (colour?.greenComponent ?? 1) < 0.2
        }
        let wordBox = Screenshot.Box(x1: 300, y1: 500, x2: 500, y2: 530)
        let underlinePng = marked(.wifiSettings, expected: [], target: .point(wordBox, label: "x", screen: 1, mark: .underline))
        let ringPng = marked(.wifiSettings, expected: [], target: .point(wordBox, label: "x", screen: 1, mark: .ring))
        let arrowPng = marked(.wifiSettings, expected: [], target: .point(
            .init(x1: 600, y1: 280, x2: 700, y2: 320), label: "x", screen: 1, mark: .arrow(from: .init(x1: 100, y1: 280, x2: 200, y2: 320), label: "y", screen: 1)
        ))
        let strokes = isRedAt(underlinePng, 400, 534) && !isRedAt(ringPng, 400, 534) && isRedAt(arrowPng, 400, 300) && isRedAt(arrowPng, 100, 300)
        print("  \(strokes ? "ok  " : "FAIL") an underline draws a red line under its box and a ring does not; an arrow outlines its start and joins the two centres")
        if !strokes { mismatches += 1 }
        for probe in probes {
            let findings = Rule.findings(in: Answered(said: Claude.Said(probe.tagged ? probe.text + " [POINT:none]" : probe.text), turn: probe.turn))
            let got = findings.map(\.rule)
            let ok = got == probe.failing && (probe.detail == nil || findings.last?.snippet == probe.detail)
            print("  \(ok ? "ok  " : "FAIL") \(probe.text.replacingOccurrences(of: "\n", with: " / ")) -> \(got)\(ok ? "" : ", expected \(probe.failing)")")
            if !ok { mismatches += 1 }
        }
        print(mismatches == 0 ? "self-test passed" : "self-test failed: \(mismatches) mismatches")
        return mismatches == 0
    }
}
