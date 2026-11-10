import AVFoundation
import os

private nonisolated let logger = Logger(subsystem: "my.rooftop.sherpa", category: "speech")

nonisolated final class SpeechConverter {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    static let bytesPerSecond = Int(format.sampleRate) * Int(format.streamDescription.pointee.mBytesPerFrame)

    private let converter: AVAudioConverter
    private let inputRate: Double

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        // Without this a multichannel input keeps channel 0 only, and speech on any other channel is lost.
        converter.downmix = true
        self.converter = converter
        self.inputRate = input.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        drain(buffer)
    }

    func finish() -> Data {
        drain(nil)
    }

    private func drain(_ buffer: AVAudioPCMBuffer?) -> Data {
        let frames = Double(buffer?.frameLength ?? 0)
        let capacity = AVAudioFrameCount((frames * Self.format.sampleRate / inputRate).rounded(.up)) + 1024
        var pcm = Data()
        var handedOver = false
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData, let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) {
            var error: NSError?
            status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let buffer, !handedOver {
                    handedOver = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = buffer == nil ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error {
                logger.error("convert failed error=\(error?.localizedDescription ?? "unknown", privacy: .public)")
            }
            if let samples = output.int16ChannelData?[0] {
                pcm.append(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
            }
        }
        return pcm
    }
}

nonisolated enum WAV {
    static func file(_ pcm: Data) -> Data {
        let description = SpeechConverter.format.streamDescription.pointee
        var header = Data()
        func tag(_ text: StaticString) { header.append(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }

        tag("RIFF")
        u32(UInt32(36 + pcm.count))
        tag("WAVE")

        tag("fmt ")
        u32(16)
        u16(1)
        u16(UInt16(description.mChannelsPerFrame))
        u32(UInt32(description.mSampleRate))
        u32(UInt32(description.mSampleRate) * description.mBytesPerFrame)
        u16(UInt16(description.mBytesPerFrame))
        u16(UInt16(description.mBitsPerChannel))

        tag("data")
        u32(UInt32(pcm.count))
        return header + pcm
    }
}
