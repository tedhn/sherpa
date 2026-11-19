import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "backup")

final class Backup {
    private enum Pass {
        case idle
        case running
        case runningThenAgain
    }

    private let journal: Journal
    private let project: Supabase.Project
    private let urlSession: URLSession
    private var ledger: Ledger
    private var pass = Pass.idle

    init(journal: Journal, project: Supabase.Project, urlSession: URLSession) {
        self.journal = journal
        self.project = project
        self.urlSession = urlSession
        ledger = Ledger(file: journal.directory.appending(path: "backed-up"))
    }

    func start() {
        follow()
        request()
    }

    /// `onChange` fires once, at the first willSet.
    private func follow() {
        withObservationTracking { _ = self.journal.sessions } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.follow()
                self.request()
            }
        }
    }

    private func request() {
        switch pass {
        case .idle:
            pass = .running
            Task { await drain() }
        case .running:
            pass = .runningThenAgain
        case .runningThenAgain:
            break
        }
    }

    private func drain() async {
        while true {
            await sync()
            guard pass == .runningThenAgain else {
                pass = .idle
                return
            }
            pass = .running
        }
    }

    private func sync() async {
        let pending = journal.sessions.reversed().flatMap(\.exchanges).filter { !ledger.contains($0.id) }
        var saved = 0
        for entry in pending {
            guard await save(entry) else { break }
            saved += 1
        }
        logger.notice("backup pass pending=\(pending.count) saved=\(saved)")
    }

    private func save(_ entry: Journal.Entry) async -> Bool {
        let id = String(entry.id.uuidString.lowercased().prefix(8))
        var stored: [String] = []
        for (index, file) in entry.shots.enumerated() {
            guard let jpeg = await Shots.read(file) else { continue }
            let path = Supabase.shotPath(entry.id, screen: index + 1)
            do throws(Supabase.Failure) {
                try await send(Supabase.upload(shot: jpeg, path: path, to: project))
            } catch {
                logger.error("backup failed id=\(id, privacy: .public) step=shot \(error.logFields, privacy: .public)")
                return false
            }
            stored.append(path)
        }
        do throws(Supabase.Failure) {
            try await send(Supabase.insert(entry, shots: stored, to: project))
        } catch {
            logger.error("backup failed id=\(id, privacy: .public) step=row \(error.logFields, privacy: .public)")
            return false
        }
        do {
            try ledger.record(entry.id)
        } catch {
            logger.error("backup failed id=\(id, privacy: .public) step=ledger detail=\(error.localizedDescription, privacy: .public)")
            return false
        }
        logger.notice("backup saved id=\(id, privacy: .public) shots=\(stored.count)/\(entry.shots.count)")
        return true
    }

    private func send(_ request: URLRequest) async throws(Supabase.Failure) {
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await urlSession.data(for: request)
        } catch {
            throw .transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard Supabase.stored(status: status, body: body) else {
            throw .refused(status: status, detail: String(decoding: body.prefix(200), as: UTF8.self))
        }
    }
}

private nonisolated struct Ledger {
    private let file: URL
    private var ids: Set<UUID>

    init(file: URL) {
        self.file = file
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        ids = Set(text.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    mutating func record(_ id: UUID) throws {
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(id.uuidString.lowercased())\n".utf8))
        ids.insert(id)
    }
}

private nonisolated enum Shots {
    @concurrent static func read(_ file: URL) async -> Data? {
        try? Data(contentsOf: file)
    }
}
