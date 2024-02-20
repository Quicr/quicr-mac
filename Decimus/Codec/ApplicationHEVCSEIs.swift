import AVFoundation

class ApplicationHEVCSEIs {
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
        HEVCUtilities.HEVCTypes.sei.rawValue << 1, 0x00,
        
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
        HEVCUtilities.HEVCTypes.sei.rawValue << 1, 0x00,
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
    
    static func parseCustomSEI(_ seiData: UnsafeRawBufferPointer, orientation: inout AVCaptureVideoOrientation?, verticalMirror: inout Bool?, timestamp: inout CMTime?, fps: inout UInt8?, sequenceNumber: inout UInt64?) throws {
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
            guard match else { return }

            let timeValue = seiData.loadUnaligned(fromByteOffset: TimestampSeiOffsets.timeValue.rawValue, as: UInt64.self)
            let timeScale = seiData.loadUnaligned(fromByteOffset: TimestampSeiOffsets.timeScale.rawValue, as: UInt32.self)
            timestamp = CMTimeMake(value: Int64(CFSwapInt64BigToHost(timeValue)), timescale: Int32(CFSwapInt32BigToHost(timeScale)))
            let tempSequence = seiData.loadUnaligned(fromByteOffset: TimestampSeiOffsets.sequence.rawValue, as: UInt64.self)
            sequenceNumber = CFSwapInt64BigToHost(tempSequence)
            fps = seiData.loadUnaligned(fromByteOffset: TimestampSeiOffsets.fps.rawValue, as: UInt8.self)
        }
    }
}
