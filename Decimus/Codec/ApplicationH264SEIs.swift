import AVFoundation

class ApplicationH264SEIs {
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
        H264Utilities.H264Types.sei.rawValue,
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
                var length = UInt32($0.count - H264Utilities.naluStartCode.count).bigEndian
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
        H264Utilities.H264Types.sei.rawValue,
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
                var length = UInt32($0.count - H264Utilities.naluStartCode.count).bigEndian
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
    
    static func parseCustomSEI(_ seiData: UnsafeRawBufferPointer, orientation: inout AVCaptureVideoOrientation?, verticalMirror: inout Bool?, timestamp: inout CMTime?, fps: inout UInt8?, sequenceNumber: inout UInt64?) throws {
        if seiData.count == orientationSei.count { // Orientation
            try parseOrientationSEI(seiData, orientation: &orientation, verticalMirror: &verticalMirror)
        } else if seiData.count == timestampSEIBytes.count { // timestamp?
            if seiData[TimestampSeiOffsets.id.rawValue] == timestampSEIBytes[TimestampSeiOffsets.id.rawValue] { // good enough - timestamp!
                try parseTimestampSEI(seiData, timestamp: &timestamp, fps: &fps, sequenceNumber: &sequenceNumber)
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
                                  timestamp: inout CMTime?,
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
        timestamp = CMTimeMake(value: timeValue, timescale: timeScale)
    }
}
