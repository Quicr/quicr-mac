import CoreMedia
import AVFoundation

// swiftlint:disable type_body_length
// swiftlint:disable function_body_length
// swiftlint:disable function_parameter_count

/// Utility functions for working with H264 bitstreams.
class H264Utilities {
    private static let logger = DecimusLogger(H264Utilities.self)

    // Bytes that precede every NALU.
    static let naluStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    // H264 frame type identifiers.
    enum H264Types: UInt8 {
        case pFrame = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
    }

    enum PacketizationError: Error {
        case missingStartCode
    }

    static func depacketize(_ data: Data,
                            groupId: UInt32,
                            objectId: UInt16,
                            format: inout CMFormatDescription?,
                            orientation: inout AVCaptureVideoOrientation?,
                            verticalMirror: inout Bool?,
                            copy: Bool) throws -> [CMSampleBuffer]? {
        if data.starts(with: naluStartCode) {
            return try depacketizeAnnexB(data,
                                         groupId: groupId,
                                         objectId: objectId,
                                         format: &format,
                                         orientation: &orientation,
                                         verticalMirror: &verticalMirror,
                                         copy: copy)
        } else {
            return try data.withUnsafeBytes {
                try depacketizeLength($0,
                                      groupId: groupId,
                                      objectId: objectId,
                                      format: &format,
                                      orientation: &orientation,
                                      verticalMirror: &verticalMirror,
                                      copy: copy)
            }
        }
    }

    static func depacketizeLength(_ data: UnsafeRawBufferPointer,
                                  groupId: UInt32,
                                  objectId: UInt16,
                                  format: inout CMFormatDescription?,
                                  orientation: inout AVCaptureVideoOrientation?,
                                  verticalMirror: inout Bool?,
                                  copy: Bool) throws -> [CMSampleBuffer]? {
        var results: [CMSampleBuffer] = []
        var offset = 0
        var spsData: Data?
        var ppsData: Data?
        var sequenceNumber: UInt64?
        var fps: UInt8?
        var timeInfo: CMSampleTimingInfo?
        while offset < data.count {
            // Get the NAL length.
            let length = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self).byteSwapped

            // Get the NALU type.
            let rawType = data.load(fromByteOffset: offset + MemoryLayout<UInt32>.size, as: UInt8.self)
            let type = H264Types(rawValue: rawType & 0x1F)
            if type == .sps {
                spsData = .init(bytesNoCopy: .init(mutating: data.baseAddress!.advanced(by: offset + MemoryLayout<UInt32>.size)), count: Int(length), deallocator: .none)
            }

            if type == .pps {
                ppsData = .init(bytesNoCopy: .init(mutating: data.baseAddress!.advanced(by: offset + MemoryLayout<UInt32>.size)), count: Int(length), deallocator: .none)
            }

            if type == .sei {
                try parseCustomSEI(.init(start: data.baseAddress!.advanced(by: offset), count: Int(length) + MemoryLayout<UInt32>.size),
                                   orientation: &orientation,
                                   verticalMirror: &verticalMirror,
                                   timeInfo: &timeInfo,
                                   fps: &fps,
                                   sequenceNumber: &sequenceNumber)
            }

            if let sps = spsData,
               let pps = ppsData {
                format = try CMVideoFormatDescription(h264ParameterSets: [sps, pps],
                                                      nalUnitHeaderLength: naluStartCode.count)
                spsData = nil
                ppsData = nil
            }

            if type == .pFrame || type == .idr {
                results.append(try buildSampleBuffer(UnsafeRawBufferPointer(start: data.baseAddress!.advanced(by: offset),
                                                                            count: Int(length) + MemoryLayout<UInt32>.size),
                                                     groupId: groupId,
                                                     objectId: objectId,
                                                     timeInfo: timeInfo,
                                                     format: format,
                                                     copy: copy,
                                                     orientation: orientation,
                                                     verticalMirror: verticalMirror,
                                                     sequenceNumber: sequenceNumber,
                                                     fps: fps))
            }
            offset += MemoryLayout<UInt32>.size + Int(length)
        }
        return results.count > 0 ? results : nil
    }

    /// Turns an H264 bitstream into CMSampleBuffer per NALU.
    /// - Parameter data The H264 data. This is used in place and will be modified,
    /// so must outlive any use of the created samples.
    /// - Parameter timeInfo The timing info for this frame.
    /// - Parameter format The current format of the stream if known.
    /// If SPS/PPS are found, it will be replaced by the found format.
    /// - Parameter sei If an SEI if found, it will be passed to this callback (start code included).
    static func depacketizeAnnexB(_ data: Data,
                                  groupId: UInt32,
                                  objectId: UInt16,
                                  format: inout CMFormatDescription?,
                                  orientation: inout AVCaptureVideoOrientation?,
                                  verticalMirror: inout Bool?,
                                  copy: Bool) throws -> [CMSampleBuffer]? {

        // Identify all NALUs by start code.
        assert(data.starts(with: naluStartCode))
        var ranges: [Range<Data.Index>] = []
        var naluRanges: [Range<Data.Index>] = []
        var startIndex = 0
        var index = 0
        var naluRangesIndex = 0
        while let range = data.range(of: .init(self.naluStartCode), in: startIndex..<data.count) {
            ranges.append(range)
            startIndex = range.upperBound
            if index > 0 {
                // Adjust previous NAL to run up to this one.
                let lastRange = ranges[index - 1]

                if naluRangesIndex > 0 {
                    if range.lowerBound <= naluRanges[naluRangesIndex - 1].upperBound {
                        index += 1
                        continue
                    }
                }

                let type = H264Types(rawValue: data[lastRange.upperBound] & 0x1F)

                // RBSP types can have data that might include a "0001". So,
                // use the payload size to get the whole sub buffer.
                if type == .sei { // RBSP
                    let payloadSize = data[lastRange.upperBound + 2]
                    let upperBound = Int(payloadSize) + lastRange.lowerBound + naluStartCode.count + 3
                    naluRanges.append(.init(lastRange.lowerBound...upperBound))

                } else {
                    naluRanges.append(.init(lastRange.lowerBound...range.lowerBound - 1))
                }
                naluRangesIndex += 1
            }
            index += 1
        }

        // Adjust the last range to run to the end of data.
        if let lastRange = ranges.last {
            let range = Range<Data.Index>(lastRange.lowerBound...data.count-1)
            naluRanges.append(range)
        }

        // Get NALU data objects (zero copy).
        var nalus: [Data] = []
        let nsData = data as NSData
        for range in naluRanges {
            nalus.append(Data(bytesNoCopy: .init(mutating: nsData.bytes.advanced(by: range.lowerBound)),
                              count: range.count,
                              deallocator: .none))
        }

        // Finally! We have all of the nalu ranges for this frame...
        var spsData: Data?
        var ppsData: Data?
        var sequenceNumber: UInt64?
        var fps: UInt8?

        // Create sample buffers from NALUs.
        var timeInfo: CMSampleTimingInfo?
        var results: [CMSampleBuffer] = []
        for index in 0..<nalus.count {
            // What type is this NALU?
            var nalu = nalus[index]
            assert(nalu.starts(with: self.naluStartCode))
            let type = H264Types(rawValue: nalu[naluStartCode.count] & 0x1F)
            let rangedData = nalu.subdata(in: naluStartCode.count..<nalu.count)

            if type == .sps {
                spsData = rangedData
            }

            if type == .pps {
                ppsData = rangedData
            }

            if type == .sei {
                try nalu.withUnsafeBytes {
                    try parseCustomSEI($0,
                                       orientation: &orientation,
                                       verticalMirror: &verticalMirror,
                                       timeInfo: &timeInfo,
                                       fps: &fps,
                                       sequenceNumber: &sequenceNumber)
                }
            }

            if let sps = spsData,
               let pps = ppsData {
                format = try CMVideoFormatDescription(h264ParameterSets: [sps, pps],
                                                      nalUnitHeaderLength: naluStartCode.count)
                spsData = nil
                ppsData = nil
            }

            if type == .pFrame || type == .idr {
                var naluDataLength = UInt32(nalu.count - naluStartCode.count).byteSwapped
                nalu.replaceSubrange(0..<naluStartCode.count, with: &naluDataLength, count: naluStartCode.count)
                try nalu.withUnsafeBytes {
                    results.append(try buildSampleBuffer($0,
                                                         groupId: groupId,
                                                         objectId: objectId,
                                                         timeInfo: timeInfo,
                                                         format: format,
                                                         copy: copy,
                                                         orientation: orientation,
                                                         verticalMirror: verticalMirror,
                                                         sequenceNumber: sequenceNumber,
                                                         fps: fps))
                }
            }
        }
        return results.count > 0 ? results : nil
    }

    static func buildSampleBuffer(_ nalu: UnsafeRawBufferPointer,
                                  groupId: UInt32,
                                  objectId: UInt16,
                                  timeInfo: CMSampleTimingInfo?,
                                  format: CMFormatDescription?,
                                  copy: Bool,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool?,
                                  sequenceNumber: UInt64?,
                                  fps: UInt8?) throws -> CMSampleBuffer {
        let timeInfo: CMSampleTimingInfo = timeInfo ?? .invalid

        let blockBuffer: CMBlockBuffer
        if copy {
            let copied: UnsafeMutableRawBufferPointer = .allocate(byteCount: nalu.count,
                                                                  alignment: MemoryLayout<UInt8>.alignment)
            nalu.copyBytes(to: copied)
            blockBuffer = try .init(buffer: copied, deallocator: { buffer, _ in
                buffer.deallocate()
            })
        } else {
            blockBuffer = try CMBlockBuffer(buffer: .init(start: .init(mutating: nalu.baseAddress!),
                                                          count: nalu.count)) { _, _ in }
        }

        let sample = try CMSampleBuffer(dataBuffer: blockBuffer,
                                        formatDescription: format,
                                        numSamples: 1,
                                        sampleTimings: [timeInfo],
                                        sampleSizes: [blockBuffer.dataLength])
        try sample.setGroupId(groupId)
        try sample.setObjectId(objectId)
        if let sequenceNumber = sequenceNumber {
            try sample.setSequenceNumber(sequenceNumber)
        }
        if let orientation = orientation {
            try sample.setOrientation(orientation)
        }
        if let verticalMirror = verticalMirror {
            try sample.setVerticalMirror(verticalMirror)
        }
        if let fps = fps {
            try sample.setFPS(fps)
        }
        return sample
    }

    fileprivate enum OrientationSeiOffsets: Int {
        case tag = 5
        case payloadLength = 6
        case orientation = 7
        case mirror = 8
    }

    static let orientationSei: [UInt8] = [
        // Start Code.
        0x00, 0x00, 0x00, 0x01,
        // SEI NALU type,
        H264Types.sei.rawValue,
        // Display orientation
        0x2f,
        // Payload length
        0x02,
        // Orientation payload.
        0x00,
        // Device position.
        0x00,
        // Stop bit
        0x80
    ]

    static func getH264OrientationSEI(orientation: AVCaptureVideoOrientation,
                                      verticalMirror: Bool,
                                      startCode: Bool) -> [UInt8] {
        var bytes = orientationSei
        if !startCode {
            bytes.withUnsafeMutableBytes {
                var length = UInt32($0.count - Self.naluStartCode.count).bigEndian
                memcpy($0.baseAddress, &length, MemoryLayout<UInt32>.size)
            }
        }
        bytes[7] = UInt8(orientation.rawValue)
        bytes[8] = verticalMirror ? 0x01 : 0x00
        return bytes
    }

    fileprivate enum TimestampSeiOffsets: Int {
        case type = 5
        case size = 6
        case id = 23
        case timeValue = 24
        case timeScale = 32
        case sequence = 36
        case fps = 44
    }

    static let timestampSEIBytes: [UInt8] = [ // total 46
        // Start Code.
        0x00, 0x00, 0x00, 0x01, // 0x28 - size
        // SEI NALU type,
        H264Types.sei.rawValue,
        // Payload type - user_data_unregistered (5)
        0x05,
        // Payload size
        0x26,
        // UUID (User Data Unregistered)
        0x2C, 0xA2, 0xDE, 0x09, 0xB5, 0x17, 0x47, 0xDC,
        0xBB, 0x55, 0xA4, 0xFE, 0x7F, 0xC2, 0xFC, 0x4E,
        // Application specific ID
        0x02, // Time ms --- offset 24 bytes from beginning
        // Time Value Int64
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // Time timescale Int32
        0x00, 0x00, 0x00, 0x00,
        // Sequence number
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        // FPS
        0x00,
        // Stop bit?
        0x80
    ]

    static func getTimestampSEIBytes(timestamp: CMTime, sequenceNumber: UInt64, fps: UInt8, startCode: Bool) -> [UInt8] {
        var bytes = timestampSEIBytes
        var networkTimeValue = timestamp.value.byteSwapped
        var networkTimeScale = timestamp.timescale.byteSwapped
        var seq = sequenceNumber.byteSwapped
        bytes[TimestampSeiOffsets.fps.rawValue] = fps
        bytes.withUnsafeMutableBytes {
            if !startCode {
                var length = UInt32($0.count - Self.naluStartCode.count).bigEndian
                memcpy($0.baseAddress, &length, MemoryLayout<UInt32>.size)
            }
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.timeValue.rawValue),
                   &networkTimeValue,
                   MemoryLayout<Int64>.size) // 8
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.timeScale.rawValue),
                   &networkTimeScale,
                   MemoryLayout<Int32>.size) // 4
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.sequence.rawValue),
                   &seq,
                   MemoryLayout<Int64>.size) // 8
        }
        return bytes
    }

    static func parseCustomSEI(_ seiData: UnsafeRawBufferPointer, orientation: inout AVCaptureVideoOrientation?, verticalMirror: inout Bool?, timeInfo: inout CMSampleTimingInfo?, fps: inout UInt8?, sequenceNumber: inout UInt64?) throws {
        if seiData.count == orientationSei.count { // Orientation
            try parseOrientationSEI(seiData, orientation: &orientation, verticalMirror: &verticalMirror)
        } else if seiData.count == timestampSEIBytes.count { // timestamp?
            if seiData[TimestampSeiOffsets.id.rawValue] == timestampSEIBytes[TimestampSeiOffsets.id.rawValue] { // good enough - timestamp!
                try parseTimestampSEI(seiData, timeInfo: &timeInfo, fps: &fps, sequenceNumber: &sequenceNumber)
            }
        }
    }

    static func parseOrientationSEI(_ seiData: UnsafeRawBufferPointer,
                                    orientation: inout AVCaptureVideoOrientation?,
                                    verticalMirror: inout Bool?) throws {
        let payloadLength = OrientationSeiOffsets.payloadLength.rawValue
        guard seiData[payloadLength] == Self.orientationSei[payloadLength] else {
            throw "Length mismatch"
        }
        orientation = .init(rawValue: .init(Int(seiData[OrientationSeiOffsets.orientation.rawValue])))
        verticalMirror = seiData[OrientationSeiOffsets.mirror.rawValue] == 1
    }

    static func parseTimestampSEI(_ seiData: UnsafeRawBufferPointer,
                                  timeInfo: inout CMSampleTimingInfo?,
                                  fps: inout UInt8?,
                                  sequenceNumber: inout UInt64?) throws {
        guard seiData[TimestampSeiOffsets.id.rawValue] == Self.timestampSEIBytes[TimestampSeiOffsets.id.rawValue] else {
            throw "ID mismatch"
        }
        guard let ptr = seiData.baseAddress else {
            throw "Bad pointer"
        }
        let timeValue = ptr.loadUnaligned(fromByteOffset: TimestampSeiOffsets.timeValue.rawValue, as: Int64.self).byteSwapped
        let timeScale = ptr.loadUnaligned(fromByteOffset: TimestampSeiOffsets.timeScale.rawValue, as: Int32.self).byteSwapped
        sequenceNumber = ptr.loadUnaligned(fromByteOffset: TimestampSeiOffsets.sequence.rawValue, as: UInt64.self).byteSwapped
        fps = seiData[TimestampSeiOffsets.fps.rawValue]
        let timeStamp = CMTimeMake(value: timeValue, timescale: timeScale)
        timeInfo = CMSampleTimingInfo(duration: .invalid,
                                      presentationTimeStamp: timeStamp,
                                      decodeTimeStamp: .invalid)
    }
}
