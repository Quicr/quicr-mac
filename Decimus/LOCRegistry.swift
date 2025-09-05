// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import Foundation

// Dictionary of header extension keys to values
typealias HeaderExtensions = [NSNumber: Data]

extension HeaderExtensions {
    mutating func setHeader(_ mediaExtension: MediaTypeHeaderExtension) throws {
        let data: Data
        switch mediaExtension {
        case .mediaType(let mediaType):
            data = mediaType.rawValue.toWireFormat()
        case .videoH264AVCCExtradata(let extradata):
            data = extradata
        case .utf8Text(let text):
            data = text.seqId.toWireFormat()
        case .videoH264AVCCMetadata(let metadata):
            data = try metadata.toWireFormat()
        case .audioOpusBitstreamData(let metadata):
            data = try metadata.toWireFormat()
        case .audioAACLCMPEG4BitstreamData(let metadata):
            data = try metadata.toWireFormat()
        }
        self[mediaExtension.extensionKey.rawValue] = data
    }

    func getHeader(_ extensionKey: MediaTypeHeaderExtensionValue) throws -> MediaTypeHeaderExtension? {
        guard let data = self[extensionKey.rawValue] else {
            return nil
        }

        switch extensionKey {
        case .mediaType:
            var offset = 0
            guard let value = try? VarInt(wireFormat: data, bytesRead: &offset),
                  let mediaType = MediaType(rawValue: value) else {
                throw "Unknown Media Type"
            }
            return .mediaType(mediaType)

        case .videoH264AVCCExtradata:
            return .videoH264AVCCExtradata(data)

        case .utf8Text:
            var offset = 0
            guard let seq = try? VarInt(wireFormat: data, bytesRead: &offset) else {
                throw "Bad sequence"
            }
            return .utf8Text(.init(seqId: seq))

        case .videoH264AVCCMetadata:
            return .videoH264AVCCMetadata(try .init(data))

        case .audioOpusBitstreamData:
            return .audioOpusBitstreamData(try .init(data))

        case .audioAACLCMPEG4BitstreamData:
            return .audioAACLCMPEG4BitstreamData(try .init(data))
        }
    }
}

protocol WireEncodable {
    func toWireFormat() throws -> Data
}

struct VideoMetadata: WireEncodable {
    /// Monotonically increasing counter for this media track.
    let seqId: VarInt
    /// Indicates presentation timestamp in timebase.
    let ptsTimestamp: VarInt
    /// Not needed if B frames are NOT used, in that case should be same value as ``ptsTimestamp``.
    let dtsTimestamp: VarInt
    /// Units used in PTS, DTS, and duration.
    let timebase: VarInt
    /// Duration in timebase, will be 0 if not set.
    let duration: VarInt
    /// EPOCH time in ms when this frame started being captured. It will be 0 if not set.
    let wallClock: VarInt

    /// Initialize Metadata from Data
    init(_ data: Data) throws {
        var offset = 0
        self.seqId = try .init(wireFormat: data, bytesRead: &offset)
        self.ptsTimestamp = try .init(wireFormat: data, bytesRead: &offset)
        self.dtsTimestamp = try .init(wireFormat: data, bytesRead: &offset)
        self.timebase = try .init(wireFormat: data, bytesRead: &offset)
        self.duration = try .init(wireFormat: data, bytesRead: &offset)
        self.wallClock = try .init(wireFormat: data, bytesRead: &offset)
    }

    /// Initialize Metadata from video sample input
    init(sample: CMSampleBuffer, sequence: UInt64, date: Date?) throws {
        // Validate we can represent this sample.
        guard sample.presentationTimeStamp.value >= 0,
              sample.decodeTimeStamp.value >= 0,
              sample.duration.value >= 0 else {
            throw "Can't represent negative values"
        }

        let pts = sample.presentationTimeStamp
        // TODO: Optional.
        let dts = sample.presentationTimeStamp
        let duration: CMTime? = sample.duration.seconds > 0 ? sample.duration : nil

        let timescale = sample.presentationTimeStamp.timescale
        if let duration {
            guard duration.timescale == pts.timescale else {
                throw "Timescale mismatch in the CSampleBuffer"
            }
        }

        self.seqId = .init(sequence)
        self.ptsTimestamp = .init(pts.value)
        self.dtsTimestamp = .init(dts.value)
        self.timebase = .init(timescale)
        if let duration {
            self.duration = .init(duration.value)
        } else {
            self.duration = 0
        }
        if let date {
            self.wallClock = .init(UInt64(date.timeIntervalSince1970 * 1000))
        } else {
            self.wallClock = 0
        }
    }

    /// Serialize Metadata to varint encodded byte array
    func toWireFormat() throws -> Data {
        // TODO:rich Optimize allocation.
        var data = Data()
        self.seqId.toWireFormat(&data)
        self.ptsTimestamp.toWireFormat(&data)
        self.dtsTimestamp.toWireFormat(&data)
        self.timebase.toWireFormat(&data)
        self.duration.toWireFormat(&data)
        self.wallClock.toWireFormat(&data)
        return data
    }
}

struct AudioBitstreamData: WireEncodable {
    let seqId: VarInt
    let ptsTimestamp: VarInt
    let timebase: VarInt
    let sampleFreq: VarInt
    let numChannels: VarInt
    let duration: VarInt
    let wallClock: VarInt

    /// Initialize Audio Metadata from ByteArray
    init(_ data: Data) throws {
        var offset = 0
        self.seqId = try .init(wireFormat: data, bytesRead: &offset)
        self.ptsTimestamp = try .init(wireFormat: data, bytesRead: &offset)
        self.timebase = try .init(wireFormat: data, bytesRead: &offset)
        self.sampleFreq = try .init(wireFormat: data, bytesRead: &offset)
        self.numChannels = try .init(wireFormat: data, bytesRead: &offset)
        self.duration = try .init(wireFormat: data, bytesRead: &offset)
        self.wallClock = try .init(wireFormat: data, bytesRead: &offset)
    }

    init(seqId: UInt64,
         ptsTimestamp: UInt64,
         timebase: UInt64,
         sampleFreq: UInt64,
         numChannels: UInt64,
         duration: UInt64,
         wallClock: UInt64) {
        self.seqId = .init(seqId)
        self.ptsTimestamp = .init(ptsTimestamp)
        self.timebase = .init(timebase)
        self.sampleFreq = .init(sampleFreq)
        self.numChannels = .init(numChannels)
        self.duration = .init(duration)
        self.wallClock = .init(wallClock)
    }

    ///
    func toWireFormat() throws -> Data {
        // TODO(rich): Optimize allocation.
        var data = Data()
        self.seqId.toWireFormat(&data)
        self.ptsTimestamp.toWireFormat(&data)
        self.timebase.toWireFormat(&data)
        self.sampleFreq.toWireFormat(&data)
        self.numChannels.toWireFormat(&data)
        self.duration.toWireFormat(&data)
        self.wallClock.toWireFormat(&data)
        return data
    }
}

struct UTF8Text {
    let seqId: VarInt
}

enum MediaType: VarInt {
    case videoH264AVC = 0x0
    case audioOpus = 0x1
    case utf8Text = 0x2
    case audioAACLCMPEG4 = 0x3
}

enum MediaTypeHeaderExtensionValue: NSNumber {
    case mediaType = 0x0A
    case videoH264AVCCMetadata = 0x0B
    case videoH264AVCCExtradata = 0x0D
    case audioOpusBitstreamData = 0x0F
    case utf8Text = 0x11
    case audioAACLCMPEG4BitstreamData = 0x13
}

enum MediaTypeHeaderExtension {
    case mediaType(MediaType)
    case videoH264AVCCMetadata(VideoMetadata)
    case videoH264AVCCExtradata(Data)
    case audioOpusBitstreamData(AudioBitstreamData)
    case utf8Text(UTF8Text)
    case audioAACLCMPEG4BitstreamData(AudioBitstreamData)

    var extensionKey: MediaTypeHeaderExtensionValue {
        switch self {
        case .mediaType:
            MediaTypeHeaderExtensionValue.mediaType
        case .videoH264AVCCMetadata:
            MediaTypeHeaderExtensionValue.videoH264AVCCMetadata
        case .videoH264AVCCExtradata:
            MediaTypeHeaderExtensionValue.videoH264AVCCExtradata
        case .audioOpusBitstreamData:
            MediaTypeHeaderExtensionValue.audioOpusBitstreamData
        case .utf8Text:
            MediaTypeHeaderExtensionValue.utf8Text
        case .audioAACLCMPEG4BitstreamData:
            MediaTypeHeaderExtensionValue.audioAACLCMPEG4BitstreamData
        }
    }
}
