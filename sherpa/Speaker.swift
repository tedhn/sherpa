import AVFoundation
import Foundation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "voice")

nonisolated enum Voice {
    struct Endpoint: Equatable, Sendable {
        static let production = URL(string: "https://tts.us.assemblyai.com/v1/speech")!

        let url: URL
        let key: String?
    }

    enum Failure: Error, Equatable, Sendable {
        case noAPIKey
        case refused(status: Int, detail: String)
        case transport(String)
        case output(String)

        var logFields: String {
            switch self {
            case .noAPIKey: "reason=noAPIKey"
            case .refused(let status, let detail): "reason=refused status=\(status) detail=\(detail)"
            case .transport(let detail): "reason=transport detail=\(detail)"
            case .output(let detail): "reason=output detail=\(detail)"
            }
        }
    }

    static let sampleRate = 24_000
    static let bytesPerSecond = sampleRate * 2
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!

    static func request(_ text: String, to endpoint: Endpoint) throws(Failure) -> URLRequest {
        guard let key = endpoint.key, !key.isEmpty else { throw .noAPIKey }
        let body: [String: Any] = [
            "text": text,
            "model_id": "assemblyai-tts-1",
            "encoding": "pcm_s16le",
            "sample_rate": sampleRate,
            "stream": true,
        ]
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return request
    }

    static func failure(status: Int, body: Data) -> Failure {
        let detail = (try? JSONDecoder().decode(WireError.self, from: body)).map { "\($0.code): \($0.message)" }
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        return .refused(status: status, detail: detail)
    }

    static func buffer(_ pcm: Data) -> AVAudioPCMBuffer {
        let frames = pcm.count / 2
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            for frame in 0..<frames {
                samples[frame] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame * 2, as: Int16.self))) / 32768
            }
        }
        return buffer
    }

    private struct WireError: Decodable {
        let code: String
        let message: String
    }
}

final class Speaker {
    private static let chunk = Voice.bytesPerSecond / 10

    private let endpoint: Voice.Endpoint
    private let urlSession: URLSession
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var saying: Task<Void, Never>?

    init(endpoint: Voice.Endpoint, urlSession: URLSession) {
        self.endpoint = endpoint
        self.urlSession = urlSession
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Voice.format)
    }

    func say(_ text: String, utterance: Int) {
        saying?.cancel()
        player.stop()
        saying = Task { await speak(text, utterance: utterance) }
    }

    private func speak(_ text: String, utterance: Int) async {
        let started = ContinuousClock.now
        let ms = { Int((started.duration(to: .now) / .milliseconds(1)).rounded()) }
        logger.notice("voice asking utterance=\(utterance) chars=\(text.count)")
        var first: Int?
        var bytes = 0
        do {
            let request = try Voice.request(text, to: endpoint)
            let (stream, response) = try await urlSession.bytes(for: request)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                var body = Data()
                for try await byte in stream { body.append(byte) }
                throw Voice.failure(status: status, body: body)
            }
            let (played, playedFinish) = AsyncStream.makeStream(of: Void.self)
            var scheduled = 0
            var pending = Data()
            func schedule(_ pcm: Data) throws {
                guard !Task.isCancelled else { throw CancellationError() }
                player.scheduleBuffer(Voice.buffer(pcm), completionCallbackType: .dataPlayedBack) { _ in playedFinish.yield() }
                scheduled += 1
                bytes += pcm.count
                if first == nil {
                    first = ms()
                    do {
                        if !engine.isRunning { try engine.start() }
                    } catch {
                        throw Voice.Failure.output(error.localizedDescription)
                    }
                    player.play()
                }
            }
            for try await byte in stream {
                pending.append(byte)
                if pending.count == Self.chunk {
                    try schedule(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if pending.count >= 2 { try schedule(pending.dropLast(pending.count % 2)) }
            for await _ in played.prefix(scheduled) {}
        } catch {
            if !Task.isCancelled {
                let failure = (error as? Voice.Failure) ?? .transport(error.localizedDescription)
                logger.error("voice failed utterance=\(utterance) ms=\(ms()) \(failure.logFields, privacy: .public)")
                engine.stop()
                return
            }
        }
        if Task.isCancelled {
            logger.notice("voice replaced utterance=\(utterance)")
            return
        }
        engine.stop()
        if let first {
            logger.notice("voice spoke utterance=\(utterance) first=\(first) ms=\(ms()) audio=\(String(format: "%.3f", Double(bytes) / Double(Voice.bytesPerSecond)), privacy: .public)")
        }
    }
}
