import Opus
import AVFoundation

/// Decodes audio using libopus.
class LibOpusDecoder: BufferDecoder {

    private let decoder: Opus.Decoder
    internal var callback: DecodedCallback?
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
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) throws {
        guard let callback = callback else { throw "Callback not set for decoder" }

        // Create buffer for the decoded data.
        let decoded: AVAudioPCMBuffer = .init(pcmFormat: decodedFormat,
                                              frameCapacity: .opusMax)!
        do {
            try data.withMemoryRebound(to: UInt8.self) {
                try decoder.decode($0, to: decoded)
            }
            let timestamp: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1)
            callback(decoded, timestamp)
        } catch {
            fatalError("Opus => Failed to decode: \(error)")
        }
        let timestamp: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1000)
        callback(decoded, timestamp)
    }
}
