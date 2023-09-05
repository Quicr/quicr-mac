import Opus
import AVFoundation
import os

enum OpusEncodeError: Error {
    case formatChange
    case badWindowSize
}

enum OpusWindowSize: TimeInterval, Codable, CaseIterable, Identifiable, CustomStringConvertible {
    case twoPointFiveMs = 0.0025
    case fiveMs = 0.005
    case tenMs = 0.01
    case twentyMs = 0.02
    case fortyMs = 0.04
    case sixtyMs = 0.06
    var id: Self { self }
    var description: String { self.rawValue.description }
}

class LibOpusEncoder {
    private static let logger = DecimusLogger(LibOpusEncoder.self)

    private let encoder: Opus.Encoder
    private let encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)

    // Data holders.
    private var encoded: Data
    private var buffer: [UInt8] = []
    private var timestamps: [UInt32] = []

    // Audio format.
    private let desiredWindowSize: OpusWindowSize
    private let format: AVAudioFormat

    /// Create an opus encoder.
    /// - Parameter format: The format of the input data.
    init(format: AVAudioFormat, desiredWindowSize: OpusWindowSize) throws {
        self.format = format
        self.desiredWindowSize = desiredWindowSize
        let appMode: Opus.Application = desiredWindowSize.rawValue < 0.01 ? .restrictedLowDelay : .voip
        try encoder = .init(format: format, application: appMode)
        let framesPerWindow: Int = .init(desiredWindowSize.rawValue * format.sampleRate)
        let windowBytes: Int = framesPerWindow * Int(format.streamDescription.pointee.mBytesPerFrame)
        encoded = .init(count: windowBytes)
    }

    func write(data: AVAudioPCMBuffer) throws -> Data {
        // Ensure we're using the format we started with.
        guard self.format == data.format else {
            throw OpusEncodeError.formatChange
        }

        // Ensure this matches our declared encode window.
        guard Double(data.frameLength) == self.desiredWindowSize.rawValue * self.format.sampleRate else {
            throw OpusEncodeError.badWindowSize
        }

        let encodeCount = try encoder.encode(data, to: &encoded)
        assert(encoded.count == encodeCount)
        return encoded
    }
}
