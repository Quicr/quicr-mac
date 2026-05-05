// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Opus
import AVFAudio

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

final class LibOpusEncoder: Sendable {
    private let logger = DecimusLogger(LibOpusEncoder.self)

    struct State: ~Copyable {
        let encoder: Opus.Encoder
        var encoded: UnsafeMutableRawBufferPointer
        init(encoder: Opus.Encoder, byteCount: Int) {
            self.encoder = encoder
            self.encoded = .allocate(byteCount: byteCount,
                                     alignment: MemoryLayout<UInt8>.alignment)
        }
        deinit {
            self.encoded.deallocate()
        }
    }
    private nonisolated(unsafe) var state: State

    // Audio format.
    private let desiredWindowSize: OpusWindowSize
    private let format: AVAudioFormat
    private let dtxSupported: Bool

    /// Create an opus encoder.
    /// - Parameter format: The format of the input data.
    init(format: AVAudioFormat, desiredWindowSize: OpusWindowSize, bitrate: Int) throws {
        self.format = format
        self.desiredWindowSize = desiredWindowSize
        let appMode: Opus.Application = desiredWindowSize.rawValue < 0.01 ? .restrictedLowDelay : .voip
        let encoder = try Opus.Encoder(format: format, application: appMode)
        let framesPerWindow: Int = .init(desiredWindowSize.rawValue * format.sampleRate)
        let windowBytes: Int = framesPerWindow * Int(format.streamDescription.pointee.mBytesPerFrame)
        self.state = .init(encoder: encoder, byteCount: windowBytes)
        _ = try encoder.ctl(request: OPUS_SET_BITRATE_REQUEST, args: [bitrate])

        // Enable DTX for VAD when using SILK layer (voip mode).
        if appMode == .voip {
            _ = try encoder.ctl(request: OPUS_SET_DTX_REQUEST, args: [1])
            self.dtxSupported = true
        } else {
            self.dtxSupported = false
        }
    }

    /// Whether the encoder detects voice activity in the most recently encoded frame, if supported.
    var voiceActive: Bool? {
        guard self.dtxSupported else { return nil }
        var inDtx: Int32 = 0
        withUnsafeMutablePointer(to: &inDtx) { ptr in
            _ = try? self.state.encoder.ctl(request: OPUS_GET_IN_DTX_REQUEST, args: [ptr])
        }
        return inDtx == 0
    }

    /// Encode PCM to opus.
    /// Must be called from a single thread.
    /// Data is only valid until the next write call.
    func write(data: AVAudioPCMBuffer) throws -> Data {
        // Ensure we're using the format we started with.
        guard self.format == data.format else {
            throw OpusEncodeError.formatChange
        }

        // Ensure this matches our declared encode window.
        guard Double(data.frameLength) == self.desiredWindowSize.rawValue * self.format.sampleRate else {
            throw OpusEncodeError.badWindowSize
        }

        let encodeCount = try self.state.encoder.encode(data, to: self.state.encoded)
        return .init(bytesNoCopy: self.state.encoded.baseAddress!,
                     count: encodeCount,
                     deallocator: .none)
    }
}
