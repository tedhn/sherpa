import Foundation
import Observation
import os

@main
@MainActor
enum JournalCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    static let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
    static let second = Data([0xFF, 0xD8, 0x02, 0x02, 0xFF, 0xD9])
    static let tag = Journal.Point(label: "File menu", screen: 2, x: 211, y: 12)

    static func fresh(_ name: String) -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "journal-check-\(getpid())", directoryHint: .isDirectory)
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    static func keep(_ journal: Journal, _ number: Int, recalled: Int, shots: [Data] = [], pointed: Journal.Point? = nil) async {
        await journal.keep(
            asked: epoch + Double(number), question: "q\(number)", screenshots: shots,
            answer: "a\(number)", pointed: pointed, recalled: recalled
        )
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    static func questions(_ journal: Journal) -> [[String]] {
        journal.sessions.map { $0.exchanges.map(\.question) }
    }

    static func main() async {
        await checkMissing()
        await checkKeep()
        await checkSessions()
        await checkReload()
        await checkGarbage()
        await checkShotFailure()
        await checkLineFailure()
        await checkObservation()
        try? FileManager.default.removeItem(at: fresh("x").deletingLastPathComponent())
        exit(failures == 0 ? 0 : 1)
    }

    static func checkMissing() async {
        print("missing directory")
        let directory = fresh("missing")
        let journal = Journal(directory: directory)
        expect(journal.sessions == [], "a directory that does not exist has no sessions")
        expect(!FileManager.default.fileExists(atPath: directory.path), "reading created nothing")
    }

    static func checkKeep() async {
        print("keep")
        let directory = fresh("keep")
        let journal = Journal(directory: directory)
        await journal.keep(asked: epoch, question: "How do I make a folder?", screenshots: [first, second], answer: "Click File.", pointed: tag, recalled: 0)
        let lines = String(decoding: (try? Data(contentsOf: directory.appending(path: "exchanges.jsonl"))) ?? Data(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        expect(mode(directory) == 0o700, "the directory is 0700, got \(String(describing: mode(directory)))")
        expect(mode(directory.appending(path: "exchanges.jsonl")) == 0o600, "exchanges.jsonl is 0600, got \(String(describing: mode(directory.appending(path: "exchanges.jsonl"))))")
        expect(lines.count == 1, "one line was appended, got \(lines.count)")
        let fields = (lines.first.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] ?? [:]
        let point = fields["pointed"] as? [String: Any] ?? [:]
        expect(fields["asked"] as? String == "2026-01-01T00:00:00.000Z", "asked is ISO 8601 with milliseconds, got \(String(describing: fields["asked"]))")
        expect(fields["recalled"] as? Int == 0, "recalled is 0, got \(String(describing: fields["recalled"]))")
        expect(fields["question"] as? String == "How do I make a folder?", "the question is kept, got \(String(describing: fields["question"]))")
        expect(fields["screens"] as? Int == 2, "screens is 2, got \(String(describing: fields["screens"]))")
        expect(fields["answer"] as? String == "Click File.", "the answer is kept, got \(String(describing: fields["answer"]))")
        expect(point["label"] as? String == "File menu" && point["screen"] as? Int == 2 && point["x"] as? Int == 211 && point["y"] as? Int == 12, "pointed is kept, got \(point)")
        let id = (fields["id"] as? String).flatMap(UUID.init(uuidString:))
        expect(id != nil, "the line has a UUID id")
        guard let id else { return }
        let one = directory.appending(path: "shots/\(id.uuidString)-1.jpg")
        let two = directory.appending(path: "shots/\(id.uuidString)-2.jpg")
        expect((try? Data(contentsOf: one)) == first, "shots/<id>-1.jpg is byte-identical to the first screenshot")
        expect((try? Data(contentsOf: two)) == second, "shots/<id>-2.jpg is byte-identical to the second screenshot")
        let entry = journal.sessions.first?.exchanges.first
        expect(entry?.shots == [one, two], "the entry derives its shot paths, got \(String(describing: entry?.shots))")
        expect(entry?.pointed == tag && entry?.question == "How do I make a folder?" && entry?.asked == epoch, "the entry equals the inputs")
    }

    static func checkSessions() async {
        print("sessions")
        let directory = fresh("sessions")
        let journal = Journal(directory: directory)
        for (number, recalled) in [0, 1, 2, 0, 1, 0].enumerated() { await keep(journal, number, recalled: recalled) }
        expect(journal.sessions.map(\.exchanges.count) == [1, 2, 3], "recalled 0,1,2,0,1,0 makes sessions of 1, 2 and 3, newest first, got \(journal.sessions.map(\.exchanges.count))")
        expect(questions(journal) == [["q5"], ["q3", "q4"], ["q0", "q1", "q2"]], "exchanges are oldest first inside each session, got \(questions(journal))")
        let late = Journal(directory: fresh("late"))
        await keep(late, 0, recalled: 3)
        expect(late.sessions.map(\.exchanges.count) == [1], "a first line with recalled 3 still opens a session")
    }

    static func checkReload() async {
        print("reload")
        let directory = fresh("sessions")
        let again = Journal(directory: directory)
        expect(again.sessions.map(\.exchanges.count) == [1, 2, 3], "a fresh Journal reads the same sessions back, got \(again.sessions.map(\.exchanges.count))")
        expect(questions(again) == [["q5"], ["q3", "q4"], ["q0", "q1", "q2"]], "and the same questions in the same order")
        let reread = Journal(directory: fresh("keep"))
        expect(reread.sessions.first?.exchanges.first?.pointed == tag && reread.sessions.first?.exchanges.first?.shots.count == 2, "and the point and the shot paths")
    }

    static func checkGarbage() async {
        print("garbage line")
        let directory = fresh("garbage")
        let journal = Journal(directory: directory)
        await keep(journal, 0, recalled: 0)
        if let handle = try? FileHandle(forWritingTo: directory.appending(path: "exchanges.jsonl")) {
            handle.seekToEndOfFile()
            handle.write(Data("{\"asked\":\"20\nnot json\n".utf8))
            try? handle.close()
        }
        await keep(journal, 1, recalled: 1)
        let again = Journal(directory: directory)
        expect(questions(again) == [["q0", "q1"]], "the lines around two garbage lines load, got \(questions(again))")
    }

    static func checkShotFailure() async {
        print("shot write failure")
        let directory = fresh("blocked")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.appending(path: "shots").path, contents: Data())
        let journal = Journal(directory: directory)
        expect(journal.sessions == [], "nothing is kept before the first keep")
        await keep(journal, 0, recalled: 0, shots: [first, second])
        let entry = journal.sessions.first?.exchanges.first
        expect(entry?.question == "q0", "the exchange is kept in memory, got \(String(describing: entry?.question))")
        expect(entry?.shots.count == 2 && entry?.shots.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } == true, "and its two shot files do not exist")
        expect(questions(Journal(directory: directory)) == [["q0"]], "the line was still written")
    }

    static func checkLineFailure() async {
        print("line write failure")
        let directory = fresh("refused")
        try? FileManager.default.createDirectory(at: directory.appending(path: "exchanges.jsonl"), withIntermediateDirectories: true)
        let journal = Journal(directory: directory)
        expect(journal.sessions == [], "nothing is kept before the first keep")
        await keep(journal, 0, recalled: 0, shots: [first])
        expect(journal.sessions == [], "a line that cannot be written keeps nothing in memory")
    }

    static func checkObservation() async {
        print("observation")
        let journal = Journal(directory: fresh("observed"))
        let fired = OSAllocatedUnfairLock(initialState: false)
        _ = withObservationTracking { journal.sessions } onChange: { fired.withLock { $0 = true } }
        expect(!fired.withLock { $0 }, "nothing fired before the keep")
        await keep(journal, 0, recalled: 0)
        expect(fired.withLock { $0 }, "reading sessions is observed and a keep fires the change")
        expect(journal.sessions.map(\.exchanges.count) == [1], "and the new session is there")
    }
}
