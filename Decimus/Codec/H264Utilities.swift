import CoreMedia
import AVFoundation


// Todo: Figure out where to put this.
extension CMSampleBuffer {
    private static let logger = DecimusLogger(H264Encoder.self)
     func getAttachmentValue(for key:  CMSampleBuffer.PerSampleAttachmentsDictionary.Key) -> Any? {
        for attachment in self.sampleAttachments {
            let val = attachment[key]
            if (val != nil) {
                return val
            }
        }
        return nil
    }
    
    func setAttachmentValue(atIndex index: Int, for key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key, value: Any?) -> Bool {
        if self.sampleAttachments.count > index {
            self.sampleAttachments[index][key] = value
            return true
        }
        return false
    }

    func isIDR() -> Bool {
        guard let value = self.getAttachmentValue(for: .dependsOnOthers) else { return false }
        guard let dependsOnOthers = value as? Bool else { return false }
        return !dependsOnOthers
    }
    
    func setGroupId(_ groupId: UInt32) {
        let keyString: CFString = "groupId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let _ = self.setAttachmentValue(atIndex: 0, for: key, value: groupId)
    }
    
    func getGroupId() -> UInt32 {
        let keyString: CFString = "groupId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt32 else { Self.logger.error("groupId not found in CMSampleBuffer", alert: true); return 0 }
        return value
    }
    
    func setObjectId(_ objectId: UInt16) {
        let keyString: CFString = "objectId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let _ = self.setAttachmentValue(atIndex: 0, for: key, value: objectId)
    }
    
    func getObjectId() -> UInt16 {
        let keyString: CFString = "objectId" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt16 else { Self.logger.error("objectId not found in CMSampleBuffer", alert: true); return 0 }
        return value
    }
    
    func setSequenceNumber(_ sequenceNumber: UInt64) {
        let keyString: CFString = "sequenceNumber" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let _ = self.setAttachmentValue(atIndex: 0, for: key, value: sequenceNumber)
    }
    
    func getSequenceNumber() -> UInt64 {
        let keyString: CFString = "sequenceNumber" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt64 else { Self.logger.error("sequenceNumber not found in CMSampleBuffer", alert: true); return 0 }
        return value
    }
    
    func setFPS(_ fps: UInt8) {
        let keyString: CFString = "FPS" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let _ = self.setAttachmentValue(atIndex: 0, for: key, value: fps)
    }
    
    func getFPS() -> UInt8 {
        let keyString: CFString = "FPS" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        guard let value = self.getAttachmentValue(for: key) as? UInt8 else { Self.logger.error("FPS not found in CMSampleBuffer", alert: true); return 0 }
        return value
    }
    
    func setOrientation(_ orientation: AVCaptureVideoOrientation?) {
        let keyString: CFString = "Orientation" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let _ = self.setAttachmentValue(atIndex: 0, for: key, value: orientation)
    }
    
    func getOrienation() -> AVCaptureVideoOrientation? {
        let keyString: CFString = "Orientation" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let value = self.getAttachmentValue(for: key) as? AVCaptureVideoOrientation
        return value
    }
    
    func setVerticalMirror(_ verticalMirror: Bool?) {
        let keyString: CFString = "verticalMirror" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let _ = self.setAttachmentValue(atIndex: 0, for: key, value: verticalMirror)
    }
    
    func getVerticalMirror() -> Bool? {
        let keyString: CFString = "verticalMirror" as CFString
        let key: CMSampleBuffer.PerSampleAttachmentsDictionary.Key = .init(rawValue: keyString)
        let value = self.getAttachmentValue(for: key) as? Bool
        return value
    }
}

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

    /// Turns an H264 Annex B bitstream into CMSampleBuffer per NALU.
    /// - Parameter data The H264 data. This is used in place and will be modified, so must outlive any use of the created samples.
    /// - Parameter timeInfo The timing info for this frame.
    /// - Parameter format The current format of the stream if known. If SPS/PPS are found, it will be replaced by the found format.
    /// - Parameter sei If an SEI if found, it will be passed to this callback (start code included).
    static func depacketize(_ data: Data,
                            groupId: UInt32,
                            objectId: UInt16,
                            format: inout CMFormatDescription?,
                            orientation: inout AVCaptureVideoOrientation?,
                            verticalMirror: inout Bool?) throws -> [CMSampleBuffer]? {
        guard data.starts(with: naluStartCode) else {
            throw PacketizationError.missingStartCode
        }
        
        // Identify all NALUs by start code.
        assert(data.starts(with: naluStartCode))
        var ranges: [Range<Data.Index>] = []
        var naluRanges : [Range<Data.Index>] = []
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
                    if range.lowerBound <= naluRanges[naluRangesIndex - 1].upperBound  {
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
        var timeValue: UInt64 = 0
        var timeScale: UInt32 = 100000
        var sequenceNumber: UInt64 = 0;
        var fps: UInt8 = 30;

        // Create sample buffers from NALUs.
        var timeInfo: CMSampleTimingInfo?
        var results: [CMSampleBuffer] = []
        for index in 0..<nalus.count {
            // What type is this NALU?
            var nalu = nalus[index]
            assert(nalu.starts(with: self.naluStartCode))
            let type = H264Types(rawValue: nalu[naluStartCode.count] & 0x1F)
            
            if type == .sps {
                spsData = nalu.subdata(in: naluStartCode.count..<nalu.count)
            }
            
            if type == .pps {
                ppsData = nalu.subdata(in: naluStartCode.count..<nalu.count)
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
            

            if let spsData = spsData,
               let ppsData = ppsData {
                format = try! CMVideoFormatDescription(h264ParameterSets: [spsData, ppsData], nalUnitHeaderLength: naluStartCode.count)
            }
        
            if type == .pFrame || type == .idr {
                results.append(try depacketizeNalu(&nalu, 
                                                   groupId: groupId,
                                                   objectId: objectId,
                                                   timeInfo: timeInfo,
                                                   format: format,
                                                   orientation: orientation,
                                                   verticalMirror: verticalMirror,
                                                   sequenceNumber: sequenceNumber,
                                                   fps: fps))
            }
        }
        return results.count > 0 ? results : nil
    }
    
    static func depacketizeNalu(_ nalu: inout Data,
                                groupId: UInt32,
                                objectId: UInt16,
                                timeInfo: CMSampleTimingInfo?,
                                format: CMFormatDescription?,
                                orientation: AVCaptureVideoOrientation?,
                                verticalMirror: Bool?,
                                sequenceNumber: UInt64,
                                fps: UInt8) throws -> CMSampleBuffer {
        guard nalu.starts(with: naluStartCode) else {
            throw PacketizationError.missingStartCode
        }

        // Change start code to length
        var naluDataLength = UInt32(nalu.count - naluStartCode.count).bigEndian
        nalu.replaceSubrange(0..<naluStartCode.count, with: &naluDataLength, count: naluStartCode.count)

        let timeInfo: CMSampleTimingInfo = timeInfo ?? .invalid

        // Return the sample buffer.
        let blockBuffer = try CMBlockBuffer(buffer: .init(start: .init(mutating: (nalu as NSData).bytes),
                                                          count: nalu.count)) { _, _ in }
        
        let sample: CMSampleBuffer =  try .init(dataBuffer: blockBuffer,
                                            formatDescription: format,
                                            numSamples: 1,
                                            sampleTimings: [timeInfo],
                                            sampleSizes: [blockBuffer.dataLength])
        sample.setGroupId(groupId)
        sample.setObjectId(objectId)
        sample.setSequenceNumber(sequenceNumber)
        sample.setOrientation(orientation)
        sample.setVerticalMirror(verticalMirror)
        sample.setFPS(fps)
        return sample
    }
}
