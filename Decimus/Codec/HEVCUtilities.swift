// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia

/// Utility functions for working with HEVC bitstreams.
class HEVCUtilities: VideoUtilities {
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

    func depacketize(_ data: Data,
                     format: inout CMFormatDescription?,
                     copy: Bool,
                     seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]? {
        if data.starts(with: Self.naluStartCode) {
            return try depacketizeAnnexB(data,
                                         format: &format,
                                         copy: copy,
                                         seiCallback: seiCallback)
        } else {
            return try data.withUnsafeBytes {
                try depacketizeLength($0,
                                      format: &format,
                                      copy: copy,
                                      seiCallback: seiCallback)
            }
        }
    }

    /// Turns an HEVC Annex B bitstream into CMSampleBuffer per NALU.
    /// - Parameter data The HEVC data.
    /// This is used in place and will be modified, so much outlive any use of the created samples.
    /// - Parameter timeInfo The timing info for this frame.
    /// - Parameter format The current format of the stream if known.
    /// If SPS/PPS are found, it will be replaced by the found format.
    /// - Parameter sei If an SEI if found, it will be passed to this callback (start code included).
    func depacketizeAnnexB(_ data: Data, // swiftlint:disable:this function_body_length
                           format: inout CMFormatDescription?,
                           copy: Bool,
                           seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]? {
        guard data.starts(with: Self.naluStartCode) else {
            throw PacketizationError.missingStartCode
        }

        // Identify all NALUs by start code.
        var ranges: [Range<Data.Index>] = []
        var naluRanges: [Range<Data.Index>] = []
        var startIndex = 0
        var index = 0
        var naluRangesIndex = 0
        while let range = data.range(of: .init(Self.naluStartCode), in: startIndex..<data.count) {
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
                    let upperBound = Int(payloadSize) + lastRange.lowerBound + Self.naluStartCode.count + 4
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

        // Create sample buffers from NALUs.
        var results: [CMBlockBuffer] = []
        for index in 0..<nalus.count {
            // What type is this NALU?
            var nalu = nalus[index]
            let naluType = (nalu[Self.naluStartCode.count] >> 1) & 0x3f
            let type = HEVCTypes(rawValue: naluType)
            let rangedData = nalu.subdata(in: Self.naluStartCode.count..<nalu.count)

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
                seiCallback(nalu)
            }

            if let vps = vpsData,
               let sps = spsData,
               let pps = ppsData {
                format = try CMVideoFormatDescription(hevcParameterSets: [vps, sps, pps],
                                                      nalUnitHeaderLength: Self.naluStartCode.count)
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

            var naluDataLength = UInt32(nalu.count - Self.naluStartCode.count).byteSwapped
            nalu.replaceSubrange(0..<Self.naluStartCode.count, with: &naluDataLength, count: Self.naluStartCode.count)
            try nalu.withUnsafeBytes {
                results.append(try H264Utilities.buildBlockBuffer($0,
                                                                  copy: copy))
            }
        }
        return results.count > 0 ? results : nil
    }

    private func depacketizeLength(_ data: UnsafeRawBufferPointer,
                                   format: inout CMFormatDescription?,
                                   copy: Bool,
                                   seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]? {
        var results: [CMBlockBuffer] = []
        var offset = 0
        var spsData: Data?
        var ppsData: Data?
        var vpsData: Data?
        while offset < data.count {
            // Get the NAL length.
            let length = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self).byteSwapped

            // Get the NALU type.
            let rawType = data.load(fromByteOffset: offset + MemoryLayout<UInt32>.size, as: UInt8.self) >> 1
            let type = HEVCTypes(rawValue: rawType & 0x3f)

            if type == .sps || type == .pps || type == .vps {
                let ptr = data.baseAddress!.advanced(by: offset + MemoryLayout<UInt32>.size)
                let data = Data(bytesNoCopy: .init(mutating: ptr),
                                count: Int(length),
                                deallocator: .none)
                switch type {
                case .sps:
                    spsData = data
                case .pps:
                    ppsData = data
                case .vps:
                    vpsData = data
                default:
                    fatalError()
                }
            }

            if type == .sei {
                seiCallback(.init(bytes: data.baseAddress!.advanced(by: offset),
                                  count: Int(length) + MemoryLayout<UInt32>.size))
            }

            if let sps = spsData,
               let pps = ppsData,
               let vps = vpsData {
                format = try CMVideoFormatDescription(hevcParameterSets: [vps, sps, pps],
                                                      nalUnitHeaderLength: Self.naluStartCode.count)
                vpsData = nil
                spsData = nil
                ppsData = nil
            }

            if type != .vps,
               type != .sps,
               type != .pps,
               type != .sei {
                let ptr = data.baseAddress!.advanced(by: offset)
                let length = Int(length) + MemoryLayout<UInt32>.size
                results.append(try H264Utilities.buildBlockBuffer(UnsafeRawBufferPointer(start: ptr,
                                                                                         count: length),
                                                                  copy: copy))
            }
            offset += MemoryLayout<UInt32>.size + Int(length)
        }
        return results.count > 0 ? results : nil
    }
}
