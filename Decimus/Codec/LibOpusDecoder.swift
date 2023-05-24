import Opus
import AVFoundation

/// Decodes audio using libopus.
class LibOpusDecoder: BufferDecoder {

    private let decoder: Opus.Decoder
    internal var callback: DecodedBufferCallback?
    let decodedFormat: AVAudioFormat

    /// Create an opus decoder.
    /// - Parameter format: Format to decode into.
    init(format: AVAudioFormat) throws {
        self.decodedFormat = format
        decoder = try .init(format: format, application: .voip)
    }

    /// Write some encoded data to the decoder.
    /// - Parameter data: Pointer to some encoded opus data.
    /// - Parameter timestamp: Timestamp of this encoded data.
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        guard let callback = callback else { fatalError("Callback not set for decoder") }

        // Get to the right pointer type.
        let unsafe: UnsafePointer<UInt8> = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let ubp: UnsafeBufferPointer<UInt8> = .init(start: unsafe, count: data.count)

        // Create buffer for the decoded data.
        let decoded: AVAudioPCMBuffer = .init(pcmFormat: decodedFormat,
                                              frameCapacity: .opusMax)!
        do {
            try decoder.decode(ubp, to: decoded)
            let timestamp: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1000)
            callback(decoded, timestamp)
        } catch {
            fatalError("Opus => Failed to decode: \(error)")
        }
    }
}
