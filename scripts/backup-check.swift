import Foundation

@main
enum BackupCheck {
    static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    static let jpegs = (1...4).map { Data([0xFF, 0xD8, UInt8($0), UInt8($0 * 2), 0xFF, 0xD9]) }
    static let tag = Journal.Point(label: "File menu", screen: 2, x: 211, y: 12)
    static let root = FileManager.default.temporaryDirectory.appending(path: "backup-check-\(getpid())", directoryHint: .isDirectory)

    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("usage: backup-check <fake-supabase binary>")
            exit(2)
        }
        guard let fake = await Fake.start(binary: CommandLine.arguments[1]) else { exit(1) }
        let log = Log()
        try? await Task.sleep(for: .seconds(1.5))

        await checkBackfill(fake, log)
        await checkSecondBackup(fake, log)
        await checkLostLedger(fake, log)
        await checkDeadProject(fake, log)
        await checkKeepAfterStart(fake, log)
        await checkMissingShot(fake, log)

        log.stop()
        fake.stop()
        try? FileManager.default.removeItem(at: root)
        exit(failures == 0 ? 0 : 1)
    }

    static func journal(_ name: String) -> (Journal, URL) {
        let directory = root.appending(path: name, directoryHint: .isDirectory)
        return (Journal(directory: directory), directory)
    }

    static func seed(_ journal: Journal) async {
        await journal.keep(asked: epoch, question: "How do I make a folder?", screenshots: [jpegs[0], jpegs[1]], answer: "Click File.", pointed: tag, recalled: 0)
        await journal.keep(asked: epoch + 30, question: "And a subfolder?", screenshots: [jpegs[2]], answer: "Same again.", pointed: nil, recalled: 1)
        await journal.keep(asked: epoch + 600, question: "What is a PDF?", screenshots: [], answer: "A document format.", pointed: nil, recalled: 0)
    }

    static func entries(_ journal: Journal) -> [Journal.Entry] {
        journal.sessions.reversed().flatMap(\.exchanges)
    }

    static func ids(_ journal: Journal) -> Set<String> {
        Set(entries(journal).map { $0.id.uuidString.lowercased() })
    }

    static func ledger(_ directory: URL) -> Set<String> {
        let text = (try? String(contentsOf: directory.appending(path: "backed-up"), encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    static func project(_ fake: Fake) -> Supabase.Project {
        Supabase.Project(url: fake.url, key: "fake")
    }

    static func checkBackfill(_ fake: Fake, _ log: Log) async {
        print("launch backfill")
        let (journal, directory) = journal("backfill")
        await seed(journal)
        let mark = log.mark()
        let backup = Backup(journal: journal, project: project(fake), urlSession: .shared)
        backup.start()
        expect(await log.wait(for: "backup pass pending=3 saved=3", since: mark), "the first pass backs up the three exchanges kept before it started")
        let all = entries(journal)
        for entry in all {
            let id = entry.id.uuidString.lowercased()
            let paths = entry.shots.indices.map { Supabase.shotPath(entry.id, screen: $0 + 1) }
            expect(fake.row(id) == Supabase.row(entry, shots: paths), "the row for \(id.prefix(8)) reaches the fake byte for byte")
            for (index, path) in paths.enumerated() {
                expect(fake.shot(path) != nil && fake.shot(path) == (try? Data(contentsOf: entry.shots[index])), "the JPEG \(path) reaches the fake byte for byte")
            }
        }
        expect(ledger(directory) == ids(journal), "backed-up lists all three ids, got \(ledger(directory).count)")
        expect(mode(directory.appending(path: "backed-up")) == 0o600, "backed-up is 0600, got \(String(describing: mode(directory.appending(path: "backed-up"))))")
        expect(log.lines(since: mark).contains { $0.hasPrefix("backup saved id=\(all[0].id.uuidString.lowercased().prefix(8)) shots=2/2") }, "the log says the first exchange saved shots=2/2")
        expect(log.lines(since: mark).contains { $0.hasPrefix("backup saved id=\(all[2].id.uuidString.lowercased().prefix(8)) shots=0/0") }, "the log says the screenshot-less exchange saved shots=0/0")
        expect(!log.lines(since: mark).contains { $0.hasPrefix("backup failed") }, "no failure was logged")
        withExtendedLifetime(backup) {}
    }

    static func checkSecondBackup(_ fake: Fake, _ log: Log) async {
        print("second backup on the same directory")
        let (journal, directory) = journal("backfill")
        let before = fake.requests
        let mark = log.mark()
        let backup = Backup(journal: journal, project: project(fake), urlSession: .shared)
        backup.start()
        expect(await log.wait(for: "backup pass pending=0 saved=0", since: mark), "the pass finds nothing pending")
        expect(fake.requests == before, "the fake received no request, \(fake.requests - before) arrived")
        expect(ledger(directory) == ids(journal), "backed-up is unchanged")
        withExtendedLifetime(backup) {}
    }

    static func checkLostLedger(_ fake: Fake, _ log: Log) async {
        print("deleted ledger")
        let (journal, directory) = journal("backfill")
        try? FileManager.default.removeItem(at: directory.appending(path: "backed-up"))
        let before = fake.lines
        let mark = log.mark()
        let backup = Backup(journal: journal, project: project(fake), urlSession: .shared)
        backup.start()
        expect(await log.wait(for: "backup pass pending=3 saved=3", since: mark), "the pass sends all three again and all three count as saved")
        let added = fake.lines.dropFirst(before.count)
        expect(added.filter { $0.hasPrefix("duplicate insert exchanges/") }.count == 3, "the fake answered three duplicate rows, got \(added.filter { $0.hasPrefix("duplicate insert") }.count)")
        expect(added.filter { $0.hasPrefix("duplicate upload exchanges/") }.count == 3, "the fake answered three duplicate uploads, got \(added.filter { $0.hasPrefix("duplicate upload") }.count)")
        expect(ledger(directory) == ids(journal), "backed-up is whole again")
        expect(!log.lines(since: mark).contains { $0.hasPrefix("backup failed") }, "no failure was logged")
        withExtendedLifetime(backup) {}
    }

    static func checkDeadProject(_ fake: Fake, _ log: Log) async {
        print("project that is down")
        let (journal, directory) = journal("dead")
        await seed(journal)
        let lineBefore = try? Data(contentsOf: directory.appending(path: "exchanges.jsonl"))
        let mark = log.mark()
        let dead = Backup(journal: journal, project: Supabase.Project(url: URL(string: "http://127.0.0.1:1")!, key: "fake"), urlSession: .shared)
        dead.start()
        expect(await log.wait(for: "backup pass pending=3 saved=0", since: mark), "nothing is saved while the project is unreachable")
        expect(ledger(directory) == [], "backed-up is empty, got \(ledger(directory).count) ids")
        expect((try? Data(contentsOf: directory.appending(path: "exchanges.jsonl"))) == lineBefore, "the journal file is untouched")
        expect(entries(journal).count == 3, "the journal still holds three exchanges")
        let failed = log.lines(since: mark).filter { $0.hasPrefix("backup failed") }
        expect(failed.count == 1 && failed[0].contains("step=shot reason=transport"), "the pass stopped at the first failure, got \(failed)")

        let catchUp = log.mark()
        let live = Backup(journal: journal, project: project(fake), urlSession: .shared)
        live.start()
        expect(await log.wait(for: "backup pass pending=3 saved=3", since: catchUp), "a Backup on the live fake catches up")
        expect(ledger(directory) == ids(journal), "and backed-up lists all three ids")
        withExtendedLifetime((dead, live)) {}
    }

    static func checkKeepAfterStart(_ fake: Fake, _ log: Log) async {
        print("keep after start")
        let (journal, directory) = journal("follow")
        let mark = log.mark()
        let backup = Backup(journal: journal, project: project(fake), urlSession: .shared)
        backup.start()
        expect(await log.wait(for: "backup pass pending=0 saved=0", since: mark), "an empty journal starts with nothing pending")
        let kept = log.mark()
        await journal.keep(asked: epoch, question: "Where is Trash?", screenshots: [jpegs[3]], answer: "In the Dock.", pointed: tag, recalled: 0)
        expect(await log.wait(for: "backup pass pending=1 saved=1", since: kept), "a keep after start is backed up without another start")
        guard let entry = entries(journal).first else { return expect(false, "the journal holds the kept exchange") }
        let path = Supabase.shotPath(entry.id, screen: 1)
        expect(fake.row(entry.id.uuidString.lowercased()) == Supabase.row(entry, shots: [path]), "its row reached the fake")
        expect(fake.shot(path) == jpegs[3], "its JPEG reached the fake")
        expect(ledger(directory) == ids(journal), "backed-up lists it")
        withExtendedLifetime(backup) {}
    }

    static func checkMissingShot(_ fake: Fake, _ log: Log) async {
        print("missing screenshot file")
        let (journal, directory) = journal("missing")
        await journal.keep(asked: epoch, question: "Where is Trash?", screenshots: [jpegs[0], jpegs[1]], answer: "In the Dock.", pointed: nil, recalled: 0)
        guard let entry = entries(journal).first else { return expect(false, "the journal holds the kept exchange") }
        try? FileManager.default.removeItem(at: entry.shots[1])
        let mark = log.mark()
        let backup = Backup(journal: journal, project: project(fake), urlSession: .shared)
        backup.start()
        expect(await log.wait(for: "backup pass pending=1 saved=1", since: mark), "the exchange is backed up")
        let stored = Supabase.shotPath(entry.id, screen: 1)
        expect(fake.row(entry.id.uuidString.lowercased()) == Supabase.row(entry, shots: [stored]), "the row lists only the stored shot and says screens 2")
        expect(fake.shot(stored) == jpegs[0], "the shot that existed reached the fake")
        expect(fake.shot(Supabase.shotPath(entry.id, screen: 2)) == nil, "the missing one did not")
        expect(log.lines(since: mark).contains { $0.hasPrefix("backup saved id=") && $0.hasSuffix("shots=1/2") }, "the log says shots=1/2")
        expect(ledger(directory) == ids(journal), "backed-up lists it")
        withExtendedLifetime(backup) {}
    }

    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
}

struct Fake {
    let process: Process
    let url: URL
    let archive: URL
    let output: URL

    static func start(binary: String) async -> Fake? {
        try? FileManager.default.createDirectory(at: BackupCheck.root, withIntermediateDirectories: true)
        let port = BackupCheck.root.appending(path: "fake.port")
        let archive = BackupCheck.root.appending(path: "fake-archive", directoryHint: .isDirectory)
        let output = BackupCheck.root.appending(path: "fake.out")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [port.path, archive.path]
        process.standardOutput = try? FileHandle(forWritingTo: output)
        do { try process.run() } catch {
            BackupCheck.expect(false, "the fake did not start: \(error.localizedDescription)")
            return nil
        }
        for _ in 0..<100 {
            if let text = try? String(contentsOf: port, encoding: .utf8), let url = URL(string: text) {
                return Fake(process: process, url: url, archive: archive, output: output)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        BackupCheck.expect(false, "the fake never wrote its port to \(port.path)")
        return nil
    }

    var lines: [String] {
        (try? String(contentsOf: output, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    var requests: Int { lines.filter { $0.hasPrefix("upload ") || $0.hasPrefix("insert ") || $0.hasPrefix("duplicate ") }.count }

    func row(_ id: String) -> Data? {
        try? Data(contentsOf: archive.appending(path: "exchanges/\(id).json"))
    }

    func shot(_ path: String) -> Data? {
        try? Data(contentsOf: archive.appending(path: "exchanges/\(path)"))
    }

    func stop() { process.terminate() }
}

struct Log {
    let process = Process()
    let file = BackupCheck.root.appending(path: "backup.log")

    init() {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "ndjson", "--predicate",
            "processIdentifier == \(getpid()) AND subsystem == \"my.rooftop.sherpa\" AND category == \"backup\"",
        ]
        process.standardOutput = try? FileHandle(forWritingTo: file)
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    var all: [String] {
        let text = (try? Data(contentsOf: file)) ?? Data()
        return text.split(separator: UInt8(ascii: "\n")).compactMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["eventMessage"] as? String
        }
    }

    func mark() -> Int { all.count }

    func lines(since mark: Int) -> [String] { Array(all.dropFirst(mark)) }

    func wait(for prefix: String, since mark: Int, upTo seconds: Double = 15) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if lines(since: mark).contains(where: { $0.hasPrefix(prefix) }) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func stop() { process.terminate() }
}
