class ApplicationH264SEIs: ApplicationSeiData {
    func getOrientationOffset(_ field: OrientationSeiField) -> Int {
        switch field {
        case .tag:
            return 5
        case .payloadLength:
            return 6
        case .orientation:
            return 7
        case .mirror:
            return 8
        }
    }

    let orientationSei: [UInt8] = [
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
    
    func getTimestampOffset(_ field: TimestampSeiField) -> Int {
        switch field {
        case .type:
            return 4
        case .size:
            return 6
        case .id:
            return 23
        case .timeValue:
            return 24
        case .timeScale:
            return 32
        case .sequence:
            return 36
        case .fps:
            return 44
        }
    }

    let timestampSei: [UInt8] = [ // total 46
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
}
