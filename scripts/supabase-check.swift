import Foundation

@main
enum SupabaseCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let started = Date(timeIntervalSince1970: 1_793_000_000.25)
    static let project = Supabase.Project(url: URL(string: "https://abc.supabase.co")!, key: "sb_publishable_x")

    static func pcm(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 % 251) })
    }

    static func utterance(
        _ final: AssemblyAI.Final, via: Dictation.Via = .endpoint, holds: Int = 1,
        after: Duration? = nil, partials: [Supabase.Partial] = [], bytes: Int
    ) -> Supabase.Utterance {
        let ended = started.addingTimeInterval(3.25)
        return Supabase.Utterance(
            id: id, started: started, ending: after.map { .released(at: ended, finalAfter: $0) } ?? .midHold(deliveredAt: ended),
            holds: holds, final: final, via: via, partials: partials, pcm: pcm(bytes)
        )
    }

    static func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    static func main() async {
        if CommandLine.arguments.contains("--live") {
            await live()
            return
        }
        let heard = utterance(
            .heard("Open the settings."), holds: 2, after: .milliseconds(2150),
            partials: [
                Supabase.Partial(sincePress: .milliseconds(840), turn: 0, end: false, text: "Open the"),
                Supabase.Partial(sincePress: .milliseconds(2100), turn: 0, end: true, text: "Open the settings."),
            ],
            bytes: 6400
        )
        let path = "11111111-2222-3333-4444-555555555555.wav"
        expect(Supabase.audioPath(heard) == path, "the audio path is the lowercased id plus .wav, got \(Supabase.audioPath(heard))")

        let heardRow = String(decoding: Supabase.row(heard, audioPath: path), as: UTF8.self)
        expect(
            heardRow == #"{"audio_ms":200,"audio_path":"11111111-2222-3333-4444-555555555555.wav","ended_at":"2026-10-26T07:33:23.500Z","failure":null,"final_after_ms":2150,"final_text":"Open the settings.","holds":2,"id":"11111111-2222-3333-4444-555555555555","outcome":"heard","partials":[{"end":false,"ms":840,"text":"Open the","turn":0},{"end":true,"ms":2100,"text":"Open the settings.","turn":0}],"started_at":"2026-10-26T07:33:20.250Z","via":"endpoint"}"#,
            "a heard two-hold utterance renders every key, got \(heardRow)"
        )

        let silent = utterance(.silence, after: .milliseconds(2000), bytes: 3200)
        let silentRow = String(decoding: Supabase.row(silent, audioPath: nil), as: UTF8.self)
        expect(
            silentRow == #"{"audio_ms":100,"audio_path":null,"ended_at":"2026-10-26T07:33:23.500Z","failure":null,"final_after_ms":2000,"final_text":null,"holds":1,"id":"11111111-2222-3333-4444-555555555555","outcome":"silence","partials":[],"started_at":"2026-10-26T07:33:20.250Z","via":"endpoint"}"#,
            "a silent utterance with no audio renders nulls and an empty partials array, got \(silentRow)"
        )

        let failed = utterance(.failed(.transport("socket closed")), via: .failure, bytes: 1600)
        let failedRow = String(decoding: Supabase.row(failed, audioPath: path), as: UTF8.self)
        expect(
            failedRow == #"{"audio_ms":50,"audio_path":"11111111-2222-3333-4444-555555555555.wav","ended_at":"2026-10-26T07:33:23.500Z","failure":"reason=transport detail=socket closed","final_after_ms":null,"final_text":null,"holds":1,"id":"11111111-2222-3333-4444-555555555555","outcome":"failed","partials":[],"started_at":"2026-10-26T07:33:20.250Z","via":"failure"}"#,
            "a failure delivered mid-hold carries its log fields and no final_after_ms, got \(failedRow)"
        )

        let upload = Supabase.upload(heard, to: project)
        expect(upload.httpMethod == "POST", "the upload is a POST")
        expect(
            upload.url?.absoluteString == "https://abc.supabase.co/storage/v1/object/utterances/11111111-2222-3333-4444-555555555555.wav",
            "the upload goes to the utterances bucket under the audio path, got \(upload.url?.absoluteString ?? "nil")"
        )
        expect(
            upload.allHTTPHeaderFields == ["apikey": "sb_publishable_x", "Authorization": "Bearer sb_publishable_x", "Content-Type": "audio/wav"],
            "the upload carries the key twice and says audio/wav, got \(upload.allHTTPHeaderFields ?? [:])"
        )
        let header: [UInt8] = Array("RIFF".utf8) + [0x24, 0x19, 0, 0] + Array("WAVEfmt ".utf8)
            + [16, 0, 0, 0, 1, 0, 1, 0, 0x80, 0x3E, 0, 0, 0, 0x7D, 0, 0, 2, 0, 16, 0] + Array("data".utf8) + [0, 0x19, 0, 0]
        expect(upload.httpBody == Data(header) + pcm(6400), "the upload body is the 44-byte WAV header plus the PCM")

        let insert = Supabase.insert(heard, audioPath: path, to: project)
        expect(insert.httpMethod == "POST", "the insert is a POST")
        expect(insert.url?.absoluteString == "https://abc.supabase.co/rest/v1/utterances", "the insert goes to the utterances table, got \(insert.url?.absoluteString ?? "nil")")
        expect(
            insert.allHTTPHeaderFields == [
                "apikey": "sb_publishable_x", "Authorization": "Bearer sb_publishable_x",
                "Content-Type": "application/json", "Prefer": "return=minimal",
            ],
            "the insert asks for no row back, which anon could not select, got \(insert.allHTTPHeaderFields ?? [:])"
        )
        expect(body(insert) == heardRow, "the insert body is the row")

        func passes(_ status: Int, _ text: String = "") -> Bool {
            (try? Supabase.check(status: status, body: Data(text.utf8))) != nil
        }
        expect(passes(200), "200 passes")
        expect(passes(201), "201 passes")
        expect(!passes(409, #"{"code":"23505"}"#), "a 409 is refused")
        expect(!passes(400, #"{"statusCode":"400","error":"Bad Request"}"#), "a 400 is refused")
        do {
            try Supabase.check(status: 401, body: Data(#"{"message":"Invalid API key"}"#.utf8))
            expect(false, "a 401 throws")
        } catch {
            expect(error == .refused(status: 401, detail: #"{"message":"Invalid API key"}"#), "a 401 is refused with the body as detail, got \(error)")
        }
        expect(Supabase.Failure.transport("offline").logFields == "reason=transport detail=offline", "transport renders its detail last")
        expect(
            Supabase.Failure.refused(status: 401, detail: "no").logFields == "reason=refused status=401 detail=no",
            "a refusal renders its status then the body"
        )

        checkExchanges()

        exit(failures == 0 ? 0 : 1)
    }

    static func checkExchanges() {
        let shots = (1...2).map { URL(filePath: "/journal/shots/\(id.uuidString)-\($0).jpg") }
        let pointing = Journal.Entry(
            id: id, asked: started, question: "How do I make a folder?", shots: shots, answer: "Click File.",
            pointed: Journal.Point(label: "File menu", screen: 2, x: 211, y: 12), recalled: 0
        )
        let paths = (1...2).map { Supabase.shotPath(id, screen: $0) }
        expect(
            paths == ["11111111-2222-3333-4444-555555555555-1.jpg", "11111111-2222-3333-4444-555555555555-2.jpg"],
            "shot paths are the lowercased id, a dash, the screen number and .jpg, got \(paths)"
        )

        let row = String(decoding: Supabase.row(pointing, shots: paths), as: UTF8.self)
        expect(
            row == #"{"answer":"Click File.","asked_at":"2026-10-26T07:33:20.250Z","id":"11111111-2222-3333-4444-555555555555","pointed":{"label":"File menu","screen":2,"x":211,"y":12},"question":"How do I make a folder?","recalled":0,"screens":2,"shots":["11111111-2222-3333-4444-555555555555-1.jpg","11111111-2222-3333-4444-555555555555-2.jpg"]}"#,
            "an exchange with a point and two shots renders every key, got \(row)"
        )

        let plain = Journal.Entry(id: id, asked: started, question: "Why?", shots: [shots[0]], answer: "Because.", pointed: nil, recalled: 2)
        let plainRow = String(decoding: Supabase.row(plain, shots: []), as: UTF8.self)
        expect(
            plainRow == #"{"answer":"Because.","asked_at":"2026-10-26T07:33:20.250Z","id":"11111111-2222-3333-4444-555555555555","pointed":null,"question":"Why?","recalled":2,"screens":1,"shots":[]}"#,
            "an exchange with no point and no stored shot renders null and an empty list, got \(plainRow)"
        )

        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let upload = Supabase.upload(shot: jpeg, path: paths[0], to: project)
        expect(upload.httpMethod == "POST", "the shot upload is a POST")
        expect(
            upload.url?.absoluteString == "https://abc.supabase.co/storage/v1/object/exchanges/11111111-2222-3333-4444-555555555555-1.jpg",
            "the shot upload goes to the exchanges bucket under its path, got \(upload.url?.absoluteString ?? "nil")"
        )
        expect(
            upload.allHTTPHeaderFields == ["apikey": "sb_publishable_x", "Authorization": "Bearer sb_publishable_x", "Content-Type": "image/jpeg"],
            "the shot upload carries the key twice and says image/jpeg, got \(upload.allHTTPHeaderFields ?? [:])"
        )
        expect(upload.httpBody == jpeg, "the shot upload body is the JPEG")

        let insert = Supabase.insert(pointing, shots: paths, to: project)
        expect(insert.httpMethod == "POST", "the exchange insert is a POST")
        expect(insert.url?.absoluteString == "https://abc.supabase.co/rest/v1/exchanges", "the exchange insert goes to the exchanges table, got \(insert.url?.absoluteString ?? "nil")")
        expect(
            insert.allHTTPHeaderFields == [
                "apikey": "sb_publishable_x", "Authorization": "Bearer sb_publishable_x",
                "Content-Type": "application/json", "Prefer": "return=minimal",
            ],
            "the exchange insert asks for no row back, got \(insert.allHTTPHeaderFields ?? [:])"
        )
        expect(body(insert) == row, "the exchange insert body is the row")

        func stored(_ status: Int, _ text: String = "") -> Bool {
            Supabase.stored(status: status, body: Data(text.utf8))
        }
        expect(stored(200), "200 counts as stored")
        expect(stored(201), "201 counts as stored")
        expect(stored(409, #"{"code":"23505"}"#), "a 409 counts as stored")
        expect(
            stored(400, #"{"statusCode":"409","error":"Duplicate","message":"The resource already exists"}"#),
            "storage's 400 Duplicate counts as stored"
        )
        expect(!stored(400, #"{"statusCode":"400","error":"Bad Request"}"#), "any other 400 does not count as stored")
        expect(!stored(401, #"{"message":"Invalid API key"}"#), "a 401 does not count as stored")
        expect(!stored(500), "a 500 does not count as stored")
        expect(!stored(0), "no response does not count as stored")
    }

    static func live() async {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["SUPABASE_URL"].flatMap(URL.init(string:)), let key = environment["SUPABASE_PUBLISHABLE_KEY"] else {
            print("  FAIL SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY must be set")
            exit(1)
        }
        let sentence = "Open the settings."
        let wav = FileManager.default.temporaryDirectory.appending(path: "supabase-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", sentence]
        try? say.run()
        say.waitUntilExit()
        guard let file = try? Data(contentsOf: wav), let data = file.range(of: Data("data".utf8)), file.count > data.upperBound + 4 else {
            print("  FAIL say wrote no audio")
            exit(1)
        }
        let saying = Supabase.Utterance(
            id: UUID(), started: .now, ending: .released(at: .now, finalAfter: .milliseconds(2000)), holds: 1,
            final: .heard(sentence), via: .endpoint, partials: [], pcm: file.dropFirst(data.upperBound + 4)
        )
        do {
            let audio = try await Archive(project: Supabase.Project(url: url, key: key), urlSession: .shared).save(saying)
            print("  ok   saved id=\(saying.id.uuidString.lowercased()) audio=\(audio ?? "none")")
        } catch {
            print("  FAIL \(error)")
            exit(1)
        }
    }
}
