import Opus
import AVFoundation

/// Decodes audio using libopus.
class LibOpusDecoder: BufferDecoder {

    private let decoder: Opus.Decoder
    internal var callback: DecodedBufferCallback?
    private let format: AVAudioFormat

    /// Create an opus decoder with the given input format.
    /// - Parameter format: The incoming opus format.
    /// - Parameter fileWrite: True to write decoded audio to a file (debugging).
    /// - Parameter errorWriter: Protocol to report errors to.
    /// - Parameter callback: A callback fired when decoded data becomes available.
    init(format: AVAudioFormat) {
        self.format = format
        do {
            guard format.isValidOpusPCMFormat else { fatalError() }
            decoder = try .init(format: format, application: .voip)
        } catch {
            fatalError("Opus => Unsupported format?")
        }
    }

    func registerCallback(callback: @escaping DecodedBufferCallback) {
        self.callback = callback
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
        let decoded: AVAudioPCMBuffer = .init(pcmFormat: format,
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
