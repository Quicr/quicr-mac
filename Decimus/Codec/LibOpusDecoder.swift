import Opus
import AVFoundation

class LibOpusDecoder: Decoder {

    let decoder: Opus.Decoder
    let callback: PipelineManager.DecodedAudio
    let format: AVAudioFormat

    init(format: AVAudioFormat, callback: @escaping PipelineManager.DecodedAudio) {
        self.callback = callback
        self.format = format
        do {
            guard format.isValidOpusPCMFormat else { fatalError() }
            decoder = try .init(format: format, application: .voip)
        } catch {
            fatalError("Opus => Unsupported format?")
        }
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        // Get to the right pointer type.
        let unsafe: UnsafePointer<UInt8> = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let ubp: UnsafeBufferPointer<UInt8> = .init(start: unsafe, count: data.count)

        // Create buffer for the decoded data.
        let decoded: AVAudioPCMBuffer = .init(pcmFormat: format,
                                              frameCapacity: .opusMax)!
        do {
            try decoder.decode(ubp, to: decoded)
            print("Opus => (\(timestamp)) Decoded: \(decoded.frameLength) frames")
            let timestamp: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1000)
            callback(decoded, timestamp)
        } catch {
            fatalError("Opus => Failed to decode: \(error)")
        }
    }
}
