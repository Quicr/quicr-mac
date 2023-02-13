import Opus
import AVFoundation

class LibOpusDecoder: Decoder {

    let decoder: Opus.Decoder
    let callback: Encoder.EncodedBufferCallback

    init(callback: @escaping Encoder.EncodedBufferCallback) {
        self.callback = callback
        let format: AVAudioFormat = .init(opusPCMFormat: .int16, sampleRate: .opus48khz, channels: 1)!
        do {
            decoder = try .init(format: format)
        } catch {
            fatalError("Opus => Unsupported format?")
        }
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        // Get to the right pointer type.
        let unsafe: UnsafePointer<UInt8> = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let ubp: UnsafeBufferPointer<UInt8> = .init(start: unsafe, count: data.count)

        // Create buffer for the decoded data.
        let outputFormat: AVAudioFormat = .init(commonFormat: .pcmFormatInt16,
                                                sampleRate: Double(48000),
                                                channels: 1,
                                                interleaved: false)!
        let decoded: AVAudioPCMBuffer = .init(pcmFormat: outputFormat, frameCapacity: LibOpusEncoder.opusFrameSize)!
        do {
            try decoder.decode(ubp, to: decoded)
        } catch {
            fatalError("Opus => Failed to decode: \(error)")
        }
        print("Opus => Decoded: \(decoded.frameLength) samples")
        callback(decoded.asMediaBuffer(timestampMs: timestamp))
    }
}
