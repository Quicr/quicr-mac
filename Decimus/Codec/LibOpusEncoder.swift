import Opus
import AVFoundation
import os

enum OpusEncodeError: Error {
    case formatChange
}

class LibOpusEncoder {
    private static let logger = DecimusLogger(LibOpusEncoder.self)

    private let encoder: Opus.Encoder

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

    func write(data: AVAudioPCMBuffer) throws -> UnsafeRawBufferPointer {
        guard self.format == data.format else { throw OpusEncodeError.formatChange }
        let encodeCount = try encoder.encode(data, to: &encoded)
        return encoded.withUnsafeBytes { return $0 }
    }
}
