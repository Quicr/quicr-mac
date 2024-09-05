// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class ApplicationHEVCSEIs: ApplicationSeiData {
    func getOrientationOffset(_ field: OrientationSeiField) -> Int {
        switch field {
        case .tag:
            return 6
        case .payloadLength:
            return 7
        case .orientation:
            return 8
        case .mirror:
            return 9
        }
    }

    let orientationSei: [UInt8] = [
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

    func getTimestampOffset(_ field: TimestampSeiField) -> Int {
        switch field {
        case .type:
            return 4
        case .size:
            return 7
        case .id:
            return 24
        case .fps:
            return 25
        }
    }

    let timestampSei: [UInt8] = [ // total 47
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
        // FPS
        0x00,
        // Stop bit?
        0x80
    ]
}
