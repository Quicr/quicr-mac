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

class LibOpusEncoder {
    private static let logger = DecimusLogger(LibOpusEncoder.self)

    private let encoder: Opus.Encoder
    private let encodeQueue: DispatchQueue = .init(label: "opus-encode", qos: .userInteractive)

    // Data holder.
    private var encoded: UnsafeMutableRawBufferPointer

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
        try encoder = .init(format: format, application: appMode)
        let framesPerWindow: Int = .init(desiredWindowSize.rawValue * format.sampleRate)
        let windowBytes: Int = framesPerWindow * Int(format.streamDescription.pointee.mBytesPerFrame)
        encoded = .allocate(byteCount: windowBytes, alignment: MemoryLayout<UInt8>.alignment)
        _ = try encoder.ctl(request: OPUS_SET_BITRATE_REQUEST, args: [bitrate])

        // Enable DTX for VAD when using SILK layer (voip mode).
        if appMode == .voip {
            _ = try encoder.ctl(request: OPUS_SET_DTX_REQUEST, args: [1])
            self.dtxSupported = true
        } else {
            self.dtxSupported = false
        }
    }

    deinit {
        encoded.deallocate()
    }

    /// Whether the encoder detects voice activity in the most recently encoded frame.
    /// Falls back to `true` when DTX is not supported (CELT-only mode).
    var voiceActive: Bool {
        guard dtxSupported else { return true }
        var inDtx: Int32 = 0
        withUnsafeMutablePointer(to: &inDtx) { ptr in
            _ = try? encoder.ctl(request: OPUS_GET_IN_DTX_REQUEST, args: [ptr])
        }
        return inDtx == 0
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

        let encodeCount = try encoder.encode(data, to: self.encoded)
        return .init(bytesNoCopy: self.encoded.baseAddress!, count: encodeCount, deallocator: .none)
    }
}
