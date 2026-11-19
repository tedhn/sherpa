import AVFoundation
import Foundation

@main
enum SpeakerCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static let endpoint = Voice.Endpoint(url: URL(string: "https://example.test/v1/speech")!, key: "k-123")

    static func main() async {
        if CommandLine.arguments.contains("--live") {
            await live()
            return
        }
        checkRequest()
        checkFailure()
        checkBuffer()
        exit(failures == 0 ? 0 : 1)
    }

    static func checkRequest() {
        print("request")
        let request = try? Voice.request("Hello, there.", to: endpoint)
        let body = String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
        expect(
            body == #"{"encoding":"pcm_s16le","model_id":"assemblyai-tts-1","sample_rate":24000,"stream":true,"text":"Hello, there."}"#,
            "the body carries the text, model, encoding, an integer rate and stream true, got \(body)"
        )
        expect(request?.url?.absoluteString == "https://example.test/v1/speech", "the request goes to the endpoint, got \(request?.url?.absoluteString ?? "nil")")
        expect(request?.httpMethod == "POST", "the request is a POST")
        expect(request?.value(forHTTPHeaderField: "Authorization") == "k-123", "the key goes bare in Authorization")
        expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json", "the body is declared as JSON")
        let slashes = try? Voice.request("a/b", to: endpoint)
        expect(String(decoding: slashes?.httpBody ?? Data(), as: UTF8.self).hasSuffix(#""text":"a/b"}"#), "a slash in the text is not escaped")
        expect(Voice.Endpoint.production.absoluteString == "https://tts.us.assemblyai.com/v1/speech", "production points at the US speech endpoint")
        for key in [nil, ""] as [String?] {
            var failure: Voice.Failure?
            do { _ = try Voice.request("x", to: Voice.Endpoint(url: endpoint.url, key: key)) } catch { failure = error }
            expect(failure == .noAPIKey, "a key of \(key.map { "'\($0)'" } ?? "nil") is noAPIKey, got \(String(describing: failure))")
        }
    }

    static func checkFailure() {
        print("failure")
        let unauthorized = Data(#"{"code":"unauthorized","message":"Invalid API key"}"#.utf8)
        expect(
            Voice.failure(status: 401, body: unauthorized) == .refused(status: 401, detail: "unauthorized: Invalid API key"),
            "the documented 401 body reads as code and message, got \(Voice.failure(status: 401, body: unauthorized))"
        )
        expect(
            Voice.failure(status: 502, body: Data("Bad Gateway".utf8)) == .refused(status: 502, detail: "Bad Gateway"),
            "a non-JSON 502 body falls back to its text"
        )
        let long = Data(String(repeating: "x", count: 300).utf8)
        expect(
            Voice.failure(status: 500, body: long) == .refused(status: 500, detail: String(repeating: "x", count: 200)),
            "a long fallback body is cut at 200 bytes"
        )
        expect(Voice.Failure.noAPIKey.logFields == "reason=noAPIKey", "noAPIKey fields")
        expect(Voice.Failure.refused(status: 401, detail: "d").logFields == "reason=refused status=401 detail=d", "refused fields")
        expect(Voice.Failure.transport("cut").logFields == "reason=transport detail=cut", "transport fields")
        expect(Voice.Failure.output("no device").logFields == "reason=output detail=no device", "output fields")
    }

    static func checkBuffer() {
        print("buffer")
        let buffer = Voice.buffer(Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x40]))
        expect(buffer.frameLength == 4, "eight bytes are four frames, got \(buffer.frameLength)")
        let samples = (0..<Int(buffer.frameLength)).map { buffer.floatChannelData![0][$0] }
        expect(samples == [-1.0, 32767.0 / 32768.0, 0, 0.5], "samples read as little-endian Int16 over 32768, got \(samples)")
        expect(buffer.format.sampleRate == 24_000 && buffer.format.channelCount == 1, "the buffer is 24 kHz mono")
        expect(Voice.buffer(Data()).frameLength == 0, "no bytes is no frames")
    }

    static func live() async {
        let found = Process()
        let output = Pipe()
        found.executableURL = URL(fileURLWithPath: "/usr/bin/sed")
        found.arguments = ["-n", "s/^ASSEMBLYAI_API_KEY *= *//p", "Config/Secrets.xcconfig"]
        found.standardOutput = output
        try? found.run()
        found.waitUntilExit()
        let key = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            print("skip no ASSEMBLYAI_API_KEY in Config/Secrets.xcconfig")
            exit(0)
        }
        let text = "Your screen shows a spreadsheet with three columns, and the cursor is on the total."
        do {
            let request = try Voice.request(text, to: Voice.Endpoint(url: Voice.Endpoint.production, key: key))
            let started = ContinuousClock.now
            let ms = { Int((started.duration(to: .now) / .milliseconds(1)).rounded()) }
            let (stream, response) = try await URLSession.shared.bytes(for: request)
            let first = ms()
            let http = response as? HTTPURLResponse
            expect(http?.statusCode == 200, "status is 200, got \(http?.statusCode ?? 0)")
            expect(
                http?.value(forHTTPHeaderField: "Content-Type") == "audio/pcm;rate=24000;channels=1",
                "content-type is audio/pcm;rate=24000;channels=1, got \(http?.value(forHTTPHeaderField: "Content-Type") ?? "nil")"
            )
            var count = 0
            for try await _ in stream { count += 1 }
            expect(count > 0 && count % 2 == 0, "a positive even byte count, got \(count)")
            print("  first byte \(first) ms, total \(ms()) ms, \(count) bytes, \(String(format: "%.3f", Double(count) / Double(Voice.bytesPerSecond))) s of audio")
        } catch {
            print("  FAIL \(error)")
            exit(1)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
