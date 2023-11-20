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

    /// Callback type to signal the caller an SEI has been found in the bitstream.
    typealias SEICallback = (Data) -> Void
    
    /// Turns an HEVC Annex B bitstream into CMSampleBuffer per NALU.
    /// - Parameter data The HEVC data. This is used in place and will be modified, so much outlive any use of the created samples.
    /// - Parameter timeInfo The timing info for this frame.
    /// - Parameter format The current format of the stream if known. If SPS/PPS are found, it will be replaced by the found format.
    /// - Parameter sei If an SEI if found, it will be passed to this callback (start code included).
    static func depacketize(_ data: Data,
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
        var vpsData: Data?
        var timeValue: UInt64 = 0
        var timeScale: UInt32 = 100_000
        var sequenceNumber: UInt64 = 0
        var fps: UInt8 = 30

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
                print("Found VPS")
                vpsData = rangedData
            }

            if type == .sps {
                print("Found SPS")
                spsData = rangedData
            }
            
            if type == .pps {
                print("Found PPS")
                ppsData = rangedData
            }

            if type == .sei {
                var seiData = nalu.subdata(in: naluStartCode.count..<nalu.count)
                if seiData.count == 6 { // Orientation
                    if seiData[2] == 0x02 { // yep - orientation
                        orientation = .init(rawValue: .init(Int(seiData[3])))
                        verticalMirror = seiData[4] == 1
                    }
                } else if seiData.count == 42 { // timestamp?
                    if seiData[19] == 2 { // good enough - timstamp!
                        seiData.withUnsafeMutableBytes {
                            guard let ptr = $0.baseAddress else { return }
                            memcpy(&timeValue, ptr.advanced(by: 20), MemoryLayout<Int64>.size)
                            memcpy(&timeScale, ptr.advanced(by: 20+8), MemoryLayout<Int32>.size)
                            memcpy(&sequenceNumber, ptr.advanced(by: 20+8+4), MemoryLayout<Int64>.size)
                            memcpy(&fps, ptr.advanced(by: 20+8+4+8), MemoryLayout<UInt8>.size)
                            timeValue = CFSwapInt64BigToHost(timeValue)
                            timeScale = CFSwapInt32BigToHost(timeScale)
                            sequenceNumber = CFSwapInt64BigToHost(sequenceNumber)
                            let timeStamp = CMTimeMake(value: Int64(timeValue),
                                                       timescale: Int32(timeScale))
                            
                            timeInfo = CMSampleTimingInfo(duration: .invalid,
                                                          presentationTimeStamp: timeStamp,
                                                          decodeTimeStamp: .invalid)
                        }
                    } else {
                        // Unhandled SEI
                    }
                }
            }
            
            if let vpsData = vpsData,
               let spsData = spsData,
               let ppsData = ppsData {
                if format == nil {
                    print("Creating format from HEVC params")
                    format = try! CMVideoFormatDescription(hevcParameterSets: [vpsData, spsData, ppsData],
                                                           nalUnitHeaderLength: naluStartCode.count)
                    print(format!)
                }
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
}
