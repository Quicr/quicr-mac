import CoreMedia
import AVFoundation

/// Utility functions for working with HEVC bitstreams.
class HEVCUtilities {
    private static let logger = DecimusLogger(HEVCUtilities.self)

    // Bytes that precede every NALU.
    static let naluStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

    // HEVC frame type identifiers.
    enum HEVCTypes: UInt8 {
        case pFrame = 1
        case idr = 19
        case vps = 32
        case sps = 33
        case pps = 34
        case sei = 39
    }

    enum PacketizationError: Error {
        case missingStartCode
    }

    /// Turns an HEVC Annex B bitstream into CMSampleBuffer per NALU.
    /// - Parameter data The HEVC data.
    /// This is used in place and will be modified, so much outlive any use of the created samples.
    /// - Parameter timeInfo The timing info for this frame.
    /// - Parameter format The current format of the stream if known.
    /// If SPS/PPS are found, it will be replaced by the found format.
    /// - Parameter sei If an SEI if found, it will be passed to this callback (start code included).
    static func depacketize(_ data: Data, // swiftlint:disable:this function_body_length
                            groupId: UInt32,
                            objectId: UInt16,
                            format: inout CMFormatDescription?,
                            orientation: inout AVCaptureVideoOrientation?,
                            verticalMirror: inout Bool?,
                            copy: Bool) throws -> [CMSampleBuffer]? {
        guard data.starts(with: naluStartCode) else {
            throw PacketizationError.missingStartCode
        }

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

                let naluType = (data[lastRange.upperBound] >> 1) & 0x3f
                let type = HEVCTypes(rawValue: naluType)

                // RBSP types can have data that include a "0001". So,
                // use the playload size to the whole sub buffer.
                if type == .sei { // RBSP
                    let payloadSize = data[lastRange.upperBound + 3]
                    let upperBound = Int(payloadSize) + lastRange.lowerBound + naluStartCode.count + 4
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
        var vpsData: Data?
        var sequenceNumber: UInt64?
        var fps: UInt8?

        // Create sample buffers from NALUs.
        var timeInfo: CMSampleTimingInfo?
        var results: [CMSampleBuffer] = []
        for index in 0..<nalus.count {
            // What type is this NALU?
            var nalu = nalus[index]
            assert(nalu.starts(with: self.naluStartCode))
            let naluType = (nalu[naluStartCode.count] >> 1) & 0x3f
            let type = HEVCTypes(rawValue: naluType)
            let rangedData = nalu.subdata(in: naluStartCode.count..<nalu.count)

            if type == .vps {
                vpsData = rangedData
            }

            if type == .sps {
                spsData = rangedData
            }

            if type == .pps {
                ppsData = rangedData
            }

            if type == .sei {
                let seiData = nalu
                if seiData.count == orientationSEI.count { // Orientation
                    if seiData[OrientationSeiOffsets.payloadLength.rawValue] == 0x02 { // yep - orientation
                        orientation = .init(rawValue: .init(Int(seiData[OrientationSeiOffsets.orientation.rawValue])))
                        verticalMirror = seiData[OrientationSeiOffsets.mirror.rawValue] == 1
                    }
                } else if seiData.count == timestampSEIBytes.count { // timestamp?
                    var match: Bool = false
                    seiData.withUnsafeBytes { seiBytes in
                        timestampSEIBytes.withUnsafeBytes { timestampBytes in
                            match = memcmp(seiBytes.baseAddress, timestampBytes.baseAddress, timestampFixedBytes) == 0
                        }
                    }

                    if match {
                        let tempTimeValue: UnsafeMutableBufferPointer<UInt64> = .allocate(capacity: 1)
                        let tempTimeScale: UnsafeMutableBufferPointer<UInt32> = .allocate(capacity: 1)
                        _ = seiData.advanced(by: TimestampSeiOffsets.timeValue.rawValue).copyBytes(to: tempTimeValue)
                        _ = seiData.advanced(by: TimestampSeiOffsets.timeScale.rawValue).copyBytes(to: tempTimeScale)
                        let tempSequence: UnsafeMutableBufferPointer<UInt64> = .allocate(capacity: 1)
                        _ = seiData.advanced(by: TimestampSeiOffsets.sequence.rawValue).copyBytes(to: tempSequence)
                        var tempFps: UInt8 = 0
                        seiData.advanced(by: TimestampSeiOffsets.fps.rawValue).copyBytes(to: &tempFps, count: 1)
                        fps = tempFps
                        let timeValue = CFSwapInt64BigToHost(tempTimeValue.baseAddress!.pointee)
                        let timeScale = CFSwapInt32BigToHost(tempTimeScale.baseAddress!.pointee)
                        sequenceNumber = CFSwapInt64BigToHost(tempSequence.baseAddress!.pointee)
                        let timeStamp = CMTimeMake(value: Int64(timeValue),
                                                   timescale: Int32(timeScale))
                        timeInfo = CMSampleTimingInfo(duration: .invalid,
                                                      presentationTimeStamp: timeStamp,
                                                      decodeTimeStamp: .invalid)
                    } else {
                        // Unhandled SEI
                    }
                }
            }

            if let vps = vpsData,
               let sps = spsData,
               let pps = ppsData {
                format = try CMVideoFormatDescription(hevcParameterSets: [vps, sps, pps],
                                                      nalUnitHeaderLength: naluStartCode.count)
                vpsData = nil
                spsData = nil
                ppsData = nil
            }

            guard type != .vps,
                  type != .sps,
                  type != .pps,
                  type != .sei else {
                continue
            }

            results.append(try H264Utilities.depacketizeNalu(&nalu,
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
        return results.count > 0 ? results : nil
    }

    fileprivate enum OrientationSeiOffsets: Int {
        case tag = 6
        case payloadLength = 7
        case orientation = 8
        case mirror = 9
    }

    fileprivate static let orientationSEI: [UInt8] = [
        // Start Code.
        0x00, 0x00, 0x00, 0x01,

        // SEI NALU type,
        HEVCTypes.sei.rawValue << 1, 0x00,

        // Display orientation
        0x2f,

        // Payload length.
        0x02,

        // Orientation payload.
        0x00,

        // Device position.
        0x00,

        // Stop.
        0x80
    ]

    static func getHEVCOrientationSEI(orientation: AVCaptureVideoOrientation,
                                      verticalMirror: Bool) -> [UInt8] {
        var bytes = orientationSEI
        bytes[8] = UInt8(orientation.rawValue)
        bytes[9] = verticalMirror ? 0x01 : 0x00
        return bytes
    }

    fileprivate enum TimestampSeiOffsets: Int {
        case timeValue = 25
        case timeScale = 33
        case sequence = 37
        case fps = 45
    }

    fileprivate static let timestampFixedBytes = 25

    fileprivate static let timestampSEIBytes: [UInt8] = [ // total 47
        // Start Code.
        0x00, 0x00, 0x00, 0x01, // 0x28 - size
        // SEI NALU type,
        HEVCTypes.sei.rawValue << 1, 0x00,
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

    static func getTimestampSEIBytes(timestamp: CMTime, sequenceNumber: UInt64, fps: UInt8) -> [UInt8] {
        var bytes = timestampSEIBytes
        var networkTimeValue = timestamp.value.bigEndian
        var networkTimeScale = timestamp.timescale.bigEndian
        var seq = sequenceNumber.bigEndian
        var fps = fps
        bytes.withUnsafeMutableBytes {
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.timeValue.rawValue),
                   &networkTimeValue,
                   MemoryLayout<UInt64>.size) // 8
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.timeScale.rawValue),
                   &networkTimeScale,
                   MemoryLayout<UInt32>.size) // 4
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.sequence.rawValue),
                   &seq,
                   MemoryLayout<UInt64>.size) // 8
            memcpy($0.baseAddress!.advanced(by: TimestampSeiOffsets.fps.rawValue),
                   &fps,
                   MemoryLayout<UInt8>.size) // 4
        }
        return bytes
    }
}
