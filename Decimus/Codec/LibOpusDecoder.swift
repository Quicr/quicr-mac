import Opus
import AVFoundation
import os

/// Decodes audio using libopus.
class LibOpusDecoder {
    private static let logger = DecimusLogger(LibOpusDecoder.self)

    private let decoder: Opus.Decoder
    let decodedFormat: AVAudioFormat

    /// Create an opus decoder.
    /// - Parameter format: Format to decode into.
    init(format: AVAudioFormat) throws {
        self.decodedFormat = format
        decoder = try .init(format: format, application: .voip)
    }

    /// Write some encoded data to the decoder.
    /// - Parameter data: Pointer to some encoded opus data.
    func write(data: Data) throws -> AVAudioPCMBuffer {
        return try decoder.decode(data)
    }

    func plc(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let plc: AVAudioPCMBuffer = .init(pcmFormat: decodedFormat, frameCapacity: frames) else {
            throw "Couldn't create PLC holder"
        }
        try decoder.decode(nil, to: plc, count: frames)
        return plc
    }
}
