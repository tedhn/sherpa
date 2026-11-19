import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "journal")

@Observable
final class Journal {
    let directory: URL
    private var oldestFirst: [Session]

    init(directory: URL) {
        self.directory = directory
        oldestFirst = Disk.load(directory)
    }

    var sessions: [Session] { oldestFirst.reversed() }

    func keep(asked: Date, question: String, screenshots: [Data], answer: String, pointed: Point?, recalled: Int) async {
        let line = Line(
            id: UUID(), asked: Line.stamp.format(asked), recalled: recalled, question: question,
            screens: screenshots.count, answer: answer, pointed: pointed
        )
        try? FileManager.default.createDirectory(
            at: directory.appending(path: "shots", directoryHint: .isDirectory),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let written = await Disk.save(screenshots, of: line.id, in: directory)
        do {
            try Disk.append(JSONEncoder().encode(line) + Data("\n".utf8), to: directory.appending(path: "exchanges.jsonl"))
        } catch {
            logger.error("journal failed step=append detail=\(error.localizedDescription, privacy: .public)")
            return
        }
        guard let entry = line.entry(in: directory) else { return }
        oldestFirst.add(entry)
        logger.notice("journal kept recalled=\(recalled) shots=\(written)/\(screenshots.count)")
    }
}

nonisolated extension Journal {
    nonisolated struct Point: Equatable, Sendable, Codable {
        let label: String
        let screen: Int
        let x: Int
        let y: Int
    }

    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let asked: Date
        let question: String
        let shots: [URL]
        let answer: String
        let pointed: Point?
        let recalled: Int

        var opensSession: Bool { recalled == 0 }
    }

    nonisolated struct Session: Identifiable, Equatable, Sendable {
        fileprivate(set) var exchanges: [Entry]

        var id: Date { exchanges[0].asked }

        fileprivate init(opening entry: Entry) {
            exchanges = [entry]
        }
    }

    static var standardDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "my.rooftop.sherpa/Journal", directoryHint: .isDirectory)
    }

    static var debugDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "my.rooftop.sherpa/Journal-Debug", directoryHint: .isDirectory)
    }
}

nonisolated extension [Journal.Session] {
    mutating func add(_ entry: Journal.Entry) {
        if entry.opensSession || isEmpty {
            append(Journal.Session(opening: entry))
        } else {
            self[endIndex - 1].exchanges.append(entry)
        }
    }
}

private nonisolated struct Line: Codable, Sendable {
    static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    let id: UUID
    let asked: String
    let recalled: Int
    let question: String
    let screens: Int
    let answer: String
    let pointed: Journal.Point?

    func entry(in directory: URL) -> Journal.Entry? {
        guard let asked = try? Self.stamp.parse(asked), screens >= 0 else { return nil }
        return Journal.Entry(
            id: id, asked: asked, question: question,
            shots: (0..<screens).map { Disk.shot($0 + 1, of: id, in: directory) },
            answer: answer, pointed: pointed, recalled: recalled
        )
    }
}

private nonisolated enum Disk {
    static func shot(_ screen: Int, of id: UUID, in directory: URL) -> URL {
        directory.appending(path: "shots/\(id.uuidString)-\(screen).jpg")
    }

    @concurrent static func save(_ jpegs: [Data], of id: UUID, in directory: URL) async -> Int {
        var written = 0
        for (index, jpeg) in jpegs.enumerated() {
            do {
                try jpeg.write(to: shot(index + 1, of: id, in: directory), options: .atomic)
                written += 1
            } catch {
                logger.error("journal failed step=shot screen=\(index + 1) detail=\(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    static func append(_ data: Data, to file: URL) throws {
        let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var remaining = data[...]
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            remaining = remaining.dropFirst(count)
        }
    }

    static func load(_ directory: URL) -> [Journal.Session] {
        let started = ContinuousClock.now
        let contents = (try? Data(contentsOf: directory.appending(path: "exchanges.jsonl"))) ?? Data()
        let decoder = JSONDecoder()
        var sessions: [Journal.Session] = []
        var entries = 0
        var skipped = 0
        for line in contents.split(separator: UInt8(ascii: "\n")) {
            guard let entry = (try? decoder.decode(Line.self, from: line))?.entry(in: directory) else {
                skipped += 1
                continue
            }
            sessions.add(entry)
            entries += 1
        }
        let ms = Int((started.duration(to: .now) / .milliseconds(1)).rounded())
        logger.notice("journal loaded entries=\(entries) sessions=\(sessions.count) skipped=\(skipped) ms=\(ms)")
        return sessions
    }
}
