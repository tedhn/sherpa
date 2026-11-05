import AVFoundation

@main
enum SpeechAudioCheck {
    nonisolated(unsafe) static var failures = 0

    static func expect(_ ok: Bool, _ what: String) {
        print(ok ? "  ok   \(what)" : "  FAIL \(what)")
        if !ok { failures += 1 }
    }

    static func sine(rate: Double, channels: Int, onChannel: Int, bufferFrames: Int) -> (AVAudioFormat, [AVAudioPCMBuffer]) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let buffers = (0..<10).map { index in
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferFrames))!
            buffer.frameLength = AVAudioFrameCount(bufferFrames)
            for channel in 0..<channels {
                for frame in 0..<bufferFrames {
                    let t = Double(index * bufferFrames + frame) / rate
                    buffer.floatChannelData![channel][frame] = channel == onChannel ? Float(0.5 * sin(2 * .pi * 1000 * t)) : 0
                }
            }
            return buffer
        }
        return (format, buffers)
    }

    static func samples(rate: Double, channels: Int = 1, onChannel: Int = 0, bufferFrames: Int) -> [Int16] {
        let (format, buffers) = sine(rate: rate, channels: channels, onChannel: onChannel, bufferFrames: bufferFrames)
        let converter = SpeechConverter(from: format)!
        var pcm = Data()
        for buffer in buffers { pcm.append(converter.convert(buffer)) }
        pcm.append(converter.finish())
        return pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    static func main() {
        let header = WAV.file(Data([0x34, 0x12, 0xFF, 0x7F]))
        let expected: [UInt8] = [
            0x52, 0x49, 0x46, 0x46, 0x28, 0x00, 0x00, 0x00, 0x57, 0x41, 0x56, 0x45,
            0x66, 0x6D, 0x74, 0x20, 0x10, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
            0x80, 0x3E, 0x00, 0x00, 0x00, 0x7D, 0x00, 0x00, 0x02, 0x00, 0x10, 0x00,
            0x64, 0x61, 0x74, 0x61, 0x04, 0x00, 0x00, 0x00, 0x34, 0x12, 0xFF, 0x7F,
        ]
        expect(Array(header) == expected, "a 4-byte payload becomes the 48-byte canonical PCM16 mono 16 kHz WAV")

        let tone = samples(rate: 48_000, bufferFrames: 4800)
        let peak = tone.map { abs(Int($0)) }.max() ?? 0
        let step = zip(tone, tone.dropFirst()).map { abs(Int($1) - Int($0)) }.max() ?? 0
        expect(tone.count == 16_000, "one second at 48 kHz in is exactly 16000 samples out, got \(tone.count)")
        expect(abs(peak - 16_384) <= 164, "a 0.5 amplitude sine peaks at 16384 within 1 %, got \(peak)")
        expect(step <= 6_393, "no sample-to-sample step beats the sine's own slope of 6393, got \(step), so buffer joins do not click")

        expect(samples(rate: 44_100, bufferFrames: 4410).count == 16_000, "one second at 44.1 kHz in is exactly 16000 samples out")

        let right = samples(rate: 48_000, channels: 2, onChannel: 1, bufferFrames: 4800)
        let rightPeak = right.map { abs(Int($0)) }.max() ?? 0
        expect(abs(rightPeak - 8_192) <= 82, "speech on channel 1 only is averaged in at half amplitude, not dropped, peak \(rightPeak)")

        exit(failures == 0 ? 0 : 1)
    }
}
