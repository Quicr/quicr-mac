import Opus
import AVFoundation

class LibOpusEncoder: Encoder {
    private let encoder: Opus.Encoder
    internal var callback: EncodedCallback?

    private var encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)

    // Data holders.
    private var encoded: Data
    private var buffer: [UInt8] = []
    private var timestamps: [UInt32] = []

    // Audio format.
    private var opusFrameSize: AVAudioFrameCount = 0
    private var opusFrameSizeBytes: UInt32 = 0
    private let desiredFrameSizeMs: Double = 10
    private let format: AVAudioFormat

    // TODO: Report errors.

    /// Create an opus encoder.
    /// - Parameter format: The format of the input data.
    init(format: AVAudioFormat) throws {
        self.format = format
        let appMode: Opus.Application = desiredFrameSizeMs < 10 ? .restrictedLowDelay : .voip
        try encoder = .init(format: format, application: appMode)
        opusFrameSize = AVAudioFrameCount(format.sampleRate * (desiredFrameSizeMs / 1000))
        opusFrameSizeBytes = opusFrameSize * format.streamDescription.pointee.mBytesPerFrame
        encoded = .init(count: Int(AVAudioFrameCount.opusMax * format.streamDescription.pointee.mBytesPerFrame))
    }

    func write(data: CMSampleBuffer, format: AVAudioFormat) {
        guard format.equivalent(other: self.format) else {
            print("Write format must match declared format")
            return
        }

        do {
            // Write our samples to the buffer
            try data.dataBuffer!.withUnsafeMutableBytes {
                buffer.append(contentsOf: $0)
            }
        } catch {
            fatalError()
        }

        // Try to encode and empty the buffer
        while UInt32(buffer.count) >= opusFrameSizeBytes {
            tryEncode(format: format)

            buffer.removeSubrange(0...Int(opusFrameSizeBytes) - 1)
        }
    }

    private func tryEncode(format: AVAudioFormat) {
        guard let callback = callback else { fatalError("Callback not set for decoder") }

        let pcm: AVAudioPCMBuffer
        do {
            pcm = try buffer.toPCM(frames: opusFrameSize, format: format)
        } catch PcmBufferError.notEnoughData(requestedBytes: let requested, availableBytes: let available) {
            fatalError("Not enough data: \(requested)/\(available)")
        } catch {
            fatalError(error.localizedDescription)
        }

        // Encode to Opus.
        do {
            let encodedBytes = try encoder.encode(pcm, to: &encoded)
            encoded.withUnsafeBytes { bytes in
                callback(Data(bytes: bytes.baseAddress!, count: Int(encodedBytes)), true)
            }
        } catch {
            print("Failed opus encode: \(error)")
        }
    }
}
