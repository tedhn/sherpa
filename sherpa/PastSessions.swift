import AppKit
import ImageIO
import os
import QuickLook
import SwiftUI

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "journal")

final class PastSessionsWindow: NSObject, NSWindowDelegate {
    private static let frameName = "PastSessions"

    private let journal: Journal
    private var window: NSWindow?

    init(journal: Journal) {
        self.journal = journal
    }

    func show() {
        let created = window == nil
        let window = self.window ?? make()
        self.window = window
        // NSApp.activate() is declined while another app is in front, even when the
        // person picked this from Sherpa's own menu, so the window would open behind.
        // Regular while open puts the window in Command-Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        logger.notice("journal window shown created=\(created ? "yes" : "no", privacy: .public)")
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        logger.notice("journal window closed")
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(rootView: PastSessionsView(journal: journal))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "Past Sessions"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.delegate = self
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 860, height: 600))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }
}

struct PastSessionsView: View {
    let journal: Journal
    @State private var picked: Journal.Session.ID?
    @State private var previewing: URL?

    var body: some View {
        let sessions = journal.sessions
        let selected = picked ?? sessions.first?.id
        let shown = sessions.first { $0.id == selected }
        NavigationSplitView {
            List(sessions, selection: Binding(get: { selected }, set: { picked = $0 })) { session in
                SessionRow(session: session)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let shown {
                SessionTranscript(session: shown, open: { previewing = $0 }).id(shown.id)
            } else {
                ContentUnavailableView(
                    "No sessions yet", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Hold Control-Option and ask something.")
                )
            }
        }
        .quickLookPreview($previewing, in: previewing == nil ? [] : (shown?.keptShots ?? []))
    }
}

private extension Journal.Session {
    var keptShots: [URL] {
        exchanges.flatMap(\.shots).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private struct SessionRow: View {
    let session: Journal.Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.exchanges[0].question).lineLimit(1)
            Text("\(Self.began.string(from: session.id)) · \(session.exchanges.count) \(session.exchanges.count == 1 ? "question" : "questions")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static let began = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

private struct SessionTranscript: View {
    let session: Journal.Session
    let open: (URL) -> Void

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(session.exchanges) { ExchangeCard(entry: $0, open: open) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: session.exchanges.last?.id) { _, last in
                withAnimation { reader.scrollTo(last, anchor: .bottom) }
            }
        }
    }
}

private struct ExchangeCard: View {
    let entry: Journal.Entry
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.asked.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(entry.question).font(.headline).textSelection(.enabled)
            if !entry.shots.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(entry.shots.enumerated()), id: \.offset) { index, url in
                        ShotTile(url: url, number: index + 1, point: entry.pointed?.screen == index + 1 ? entry.pointed : nil, open: open)
                    }
                }
            }
            Text(entry.answer).textSelection(.enabled)
        }
    }
}

private struct ShotTile: View {
    static let height: CGFloat = 180

    enum Loaded {
        case loading
        case ready(Thumbnail)
        case lost
    }

    let url: URL
    let number: Int
    let point: Journal.Point?
    let open: (URL) -> Void
    @State private var loaded = Loaded.loading

    var body: some View {
        Group {
            switch loaded {
            case .loading:
                placeholder
            case .ready(let thumbnail):
                Button { open(url) } label: { tile(thumbnail) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Screenshot \(number)")
            case .lost:
                placeholder.overlay { Text("Screenshot not kept").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: url) {
            loaded = await Thumbnail.load(url).map(Loaded.ready) ?? .lost
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary).aspectRatio(1.6, contentMode: .fit).frame(maxHeight: Self.height)
    }

    private func tile(_ thumbnail: Thumbnail) -> some View {
        Image(decorative: thumbnail.image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if let point {
                    GeometryReader { proxy in
                        let x = min(max(CGFloat(point.x) / thumbnail.fullSize.width, 0), 1) * proxy.size.width
                        let y = min(max(CGFloat(point.y) / thumbnail.fullSize.height, 0), 1) * proxy.size.height
                        Circle().stroke(.red, lineWidth: 3).frame(width: 22, height: 22).position(x: x, y: y)
                        Text(point.label)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .background(.red, in: Capsule())
                            .position(x: x, y: min(y + 22, proxy.size.height - 8))
                    }
                }
            }
            .frame(maxHeight: Self.height)
    }
}

nonisolated struct Thumbnail: Sendable {
    let image: CGImage
    let fullSize: CGSize

    @concurrent static func load(_ url: URL) async -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
              ] as CFDictionary)
        else { return nil }
        return Thumbnail(image: image, fullSize: CGSize(width: width, height: height))
    }
}
