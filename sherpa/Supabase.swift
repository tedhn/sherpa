import Foundation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "archive")

nonisolated enum Supabase {
    struct Project: Equatable, Sendable {
        let url: URL
        let key: String
    }

    struct Partial: Equatable, Sendable {
        let sincePress: Duration
        let turn: Int
        let end: Bool
        let text: String
    }

    enum Ending: Equatable, Sendable {
        case released(at: Date, finalAfter: Duration)
        case midHold(deliveredAt: Date)
    }

    struct Utterance: Equatable, Sendable {
        let id: UUID
        let started: Date
        let ending: Ending
        let holds: Int
        let final: AssemblyAI.Final
        let via: Dictation.Via
        let partials: [Partial]
        let pcm: Data
    }

    static func audioPath(_ utterance: Utterance) -> String {
        "\(utterance.id.uuidString.lowercased()).wav"
    }

    static func upload(_ utterance: Utterance, to project: Project) -> URLRequest {
        var request = request(project.url.appending(path: "storage/v1/object/utterances/\(audioPath(utterance))"), project)
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = WAV.file(utterance.pcm)
        return request
    }

    static func insert(_ utterance: Utterance, audioPath: String?, to project: Project) -> URLRequest {
        var request = request(project.url.appending(path: "rest/v1/utterances"), project)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = row(utterance, audioPath: audioPath)
        return request
    }

    static func row(_ utterance: Utterance, audioPath: String?) -> Data {
        let (outcome, text, failure): (String, String?, String?) = switch utterance.final {
        case .heard(let text): ("heard", text, nil)
        case .silence: ("silence", nil, nil)
        case .failed(let failure): ("failed", nil, failure.logFields)
        }
        let (ended, finalAfter): (Date, Duration?) = switch utterance.ending {
        case .released(let at, let finalAfter): (at, finalAfter)
        case .midHold(let deliveredAt): (deliveredAt, nil)
        }
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let object: [String: Any] = [
            "id": utterance.id.uuidString.lowercased(),
            "started_at": utterance.started.formatted(stamp),
            "ended_at": ended.formatted(stamp),
            "holds": utterance.holds,
            "final_text": orNull(text),
            "outcome": outcome,
            "via": utterance.via.rawValue,
            "failure": orNull(failure),
            "final_after_ms": orNull(finalAfter.map(milliseconds)),
            "audio_ms": utterance.pcm.count * 1000 / SpeechConverter.bytesPerSecond,
            "partials": utterance.partials.map { ["ms": milliseconds($0.sincePress), "turn": $0.turn, "end": $0.end, "text": $0.text] },
            "audio_path": orNull(audioPath),
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func check(status: Int, body: Data) throws(Failure) {
        guard (200..<300).contains(status) else {
            throw .refused(status: status, detail: String(decoding: body.prefix(200), as: UTF8.self))
        }
    }

    enum Failure: Error, Equatable, Sendable {
        case refused(status: Int, detail: String)
        case transport(String)

        var logFields: String {
            switch self {
            case .refused(let status, let detail): "reason=refused status=\(status) detail=\(detail)"
            case .transport(let detail): "reason=transport detail=\(detail)"
            }
        }
    }

    private static func request(_ url: URL, _ project: Project) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(project.key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(project.key)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    private static func orNull(_ value: (some Any)?) -> Any {
        if let value { return value }
        return NSNull()
    }
}

final class Archive {
    private let project: Supabase.Project
    private let urlSession: URLSession

    init(project: Supabase.Project, urlSession: URLSession) {
        self.project = project
        self.urlSession = urlSession
    }

    func save(_ utterance: Supabase.Utterance) async throws(Supabase.Failure) -> String? {
        var audioPath: String? = Supabase.audioPath(utterance)
        do throws(Supabase.Failure) {
            try await send(Supabase.upload(utterance, to: project))
        } catch {
            logger.error("archive failed id=\(utterance.id.uuidString.lowercased(), privacy: .public) step=upload \(error.logFields, privacy: .public)")
            audioPath = nil
        }
        try await send(Supabase.insert(utterance, audioPath: audioPath, to: project))
        return audioPath
    }

    func keep(_ utterance: Supabase.Utterance, number: Int) {
        Task {
            do throws(Supabase.Failure) {
                let audio = try await save(utterance)
                logger.notice("archive saved utterance=\(number) id=\(utterance.id.uuidString.lowercased(), privacy: .public) audio=\(audio ?? "none", privacy: .public)")
            } catch {
                logger.error("archive failed utterance=\(number) step=insert \(error.logFields, privacy: .public)")
            }
        }
    }

    private func send(_ request: URLRequest) async throws(Supabase.Failure) {
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await urlSession.data(for: request)
        } catch {
            throw .transport(error.localizedDescription)
        }
        try Supabase.check(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
    }
}
