// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia

/// Utility functions for working with H264 bitstreams.
class H264Utilities: VideoUtilities {
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

    private func depacketizeLength(_ data: UnsafeRawBufferPointer,
                                   format: inout CMFormatDescription?,
                                   copy: Bool,
                                   seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]? {
        var results: [CMBlockBuffer] = []
        var offset = 0
        var spsData: Data?
        var ppsData: Data?
        while offset < data.count {
            // Get the NAL length.
            let length = data.loadUnaligned(fromByteOffset: offset, as: UInt32.self).byteSwapped

            // Get the NALU type.
            let rawType = data.load(fromByteOffset: offset + MemoryLayout<UInt32>.size, as: UInt8.self)
            let type = H264Types(rawValue: rawType & 0x1F)
            if type == .sps {
                let ptr = data.baseAddress!.advanced(by: offset + MemoryLayout<UInt32>.size)
                spsData = .init(bytesNoCopy: .init(mutating: ptr),
                                count: Int(length),
                                deallocator: .none)
            }

            if type == .pps {
                let ptr = data.baseAddress!.advanced(by: offset + MemoryLayout<UInt32>.size)
                ppsData = .init(bytesNoCopy: .init(mutating: ptr),
                                count: Int(length),
                                deallocator: .none)
            }

            if type == .sei {
                seiCallback(.init(bytes: data.baseAddress!.advanced(by: offset),
                                  count: Int(length) + MemoryLayout<UInt32>.size))
            }

            if let sps = spsData,
               let pps = ppsData {
                format = try CMVideoFormatDescription(h264ParameterSets: [sps, pps],
                                                      nalUnitHeaderLength: Self.naluStartCode.count)
                spsData = nil
                ppsData = nil
            }

            if type == .pFrame || type == .idr {
                let ptr = data.baseAddress!.advanced(by: offset)
                let length = Int(length) + MemoryLayout<UInt32>.size
                results.append(try Self.buildBlockBuffer(UnsafeRawBufferPointer(start: ptr,
                                                                                count: length),
                                                         copy: copy))
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
    private func depacketizeAnnexB(_ data: Data,
                                   format: inout CMFormatDescription?,
                                   copy: Bool,
                                   seiCallback: (Data) -> Void) throws -> [CMBlockBuffer]? {
        // Identify all NALUs by start code.
        assert(data.starts(with: Self.naluStartCode))
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

                let type = H264Types(rawValue: data[lastRange.upperBound] & 0x1F)

                // RBSP types can have data that might include a "0001". So,
                // use the payload size to get the whole sub buffer.
                if type == .sei { // RBSP
                    let payloadSize = data[lastRange.upperBound + 2]
                    let upperBound = Int(payloadSize) + lastRange.lowerBound + Self.naluStartCode.count + 3
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

        // Create block buffers from NALUs.
        var results: [CMBlockBuffer] = []
        for index in 0..<nalus.count {
            // What type is this NALU?
            var nalu = nalus[index]
            assert(nalu.starts(with: Self.naluStartCode))
            let type = H264Types(rawValue: nalu[Self.naluStartCode.count] & 0x1F)
            let rangedData = nalu.subdata(in: Self.naluStartCode.count..<nalu.count)

            if type == .sps {
                spsData = rangedData
            }

            if type == .pps {
                ppsData = rangedData
            }

            if type == .sei {
                seiCallback(nalu)
            }

            if let sps = spsData,
               let pps = ppsData {
                format = try CMVideoFormatDescription(h264ParameterSets: [sps, pps],
                                                      nalUnitHeaderLength: Self.naluStartCode.count)
                spsData = nil
                ppsData = nil
            }

            if type == .pFrame || type == .idr {
                var naluDataLength = UInt32(nalu.count - Self.naluStartCode.count).byteSwapped
                nalu.replaceSubrange(0..<Self.naluStartCode.count,
                                     with: &naluDataLength,
                                     count: Self.naluStartCode.count)
                try nalu.withUnsafeBytes {
                    results.append(try Self.buildBlockBuffer($0,
                                                             copy: copy))
                }
            }
        }
        return results.count > 0 ? results : nil
    }

    static func buildBlockBuffer(_ nalu: UnsafeRawBufferPointer,
                                 copy: Bool) throws -> CMBlockBuffer {
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
        return blockBuffer
    }
}
