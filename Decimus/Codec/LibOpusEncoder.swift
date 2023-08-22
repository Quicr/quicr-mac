import Opus
import AVFoundation
import os

enum OpusEncodeError: Error {
    case formatChange
}

class LibOpusEncoder: Encoder {
    private static let logger = DecimusLogger(LibOpusEncoder.self)

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

    // TODO: Change to a regular non-callback return.
    func write(data: AVAudioPCMBuffer) throws {
        guard self.format == data.format else {
            throw OpusEncodeError.formatChange
        }
        let encodeCount = try encoder.encode(data, to: &encoded)
        callback?(encoded, true)
    }

    func write(data: CMSampleBuffer, format: AVAudioFormat) throws {
        guard format.equivalent(other: self.format) else {
            throw "Write format must match declared format"
        }

        // Write our samples to the buffer
        try data.dataBuffer!.withUnsafeMutableBytes {
            buffer.append(contentsOf: $0)
        }

        // Try to encode and empty the buffer
        while UInt32(buffer.count) >= opusFrameSizeBytes {
            guard let callback = callback else { throw "Callback not set for decoder" }
            let pcm: AVAudioPCMBuffer = try buffer.toPCM(frames: opusFrameSize, format: format)
            let encodedBytes = try encoder.encode(pcm, to: &encoded)
            encoded.withUnsafeBytes { bytes in
                callback(Data(bytes: bytes.baseAddress!, count: Int(encodedBytes)), true)
            }
            buffer.removeSubrange(0...Int(opusFrameSizeBytes) - 1)
        }
    }
}
