import Opus
import AVFoundation

class LibOpusEncoder: Encoder {
    private let encoder: Opus.Encoder
    internal var callback: EncodedBufferCallback?

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

    func write(data: MediaBuffer) {

        guard let format = data.userData as? AVAudioFormat else {
            print("Couldn't get format from audio data")
            return
        }

        guard format.equivalent(other: self.format) else {
            print("Write format must match declared format")
            return
        }

        // Write our samples to the buffer
        data.buffer.withUnsafeBytes {
            buffer.append(contentsOf: $0)
        }

        timestamps.append(data.timestampMs)

        // Try to encode and empty the buffer
        while UInt32(buffer.count) >= opusFrameSizeBytes {
            tryEncode(format: format)

            buffer.removeSubrange(0...Int(opusFrameSizeBytes) - 1)
            if buffer.count > 0 && timestamps.count != 1 {
                timestamps.removeFirst()
            }
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
                callback(.init(buffer: .init(start: bytes.baseAddress, count: Int(encodedBytes)),
                               timestampMs: timestamps.first!))
            }
        } catch {
            print("Failed opus encode: \(error)")
        }
    }
}
