// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import Decimus
import Foundation
import XCTest
import CoreMedia

final class TestApplicationSEIs: XCTestCase {
    func testGetTimestampBytes() {
        testGetTimestampBytes(startCode: true, seiData: ApplicationH264SEIs())
        testGetTimestampBytes(startCode: false, seiData: ApplicationH264SEIs())
        testGetTimestampBytes(startCode: true, seiData: ApplicationHEVCSEIs())
        testGetTimestampBytes(startCode: false, seiData: ApplicationHEVCSEIs())
    }

    func testGetTimestampBytes(startCode: Bool, seiData: ApplicationSeiData) {
        let time = CMTime(seconds: 1234, preferredTimescale: 5678)
        let timestampSei = TimestampSei(timestamp: time, sequenceNumber: 1, fps: 30)
        let bytes = timestampSei.getBytes(seiData, startCode: startCode)
        XCTAssert(bytes.count == seiData.timestampSei.count)
        if startCode {
            XCTAssert(bytes.starts(with: H264Utilities.naluStartCode))
        } else {
            var length = UInt32(bytes.count - H264Utilities.naluStartCode.count).bigEndian
            bytes.withUnsafeBytes {
                XCTAssert(memcmp($0.baseAddress, &length, 4) == 0)
            }
        }
    }

    func testGetOrientationBytes() {
        testGetOrientationBytes(startCode: true, seiData: ApplicationH264SEIs())
        testGetOrientationBytes(startCode: false, seiData: ApplicationH264SEIs())
        testGetOrientationBytes(startCode: true, seiData: ApplicationHEVCSEIs())
        testGetOrientationBytes(startCode: false, seiData: ApplicationHEVCSEIs())
    }

    func testGetOrientationBytes(startCode: Bool, seiData: ApplicationSeiData) {
        let orientationSei = OrientationSei(orientation: .portrait, verticalMirror: false)
        let bytes = orientationSei.getBytes(seiData, startCode: startCode)
        XCTAssert(bytes.count == seiData.orientationSei.count)
        if startCode {
            XCTAssert(bytes.starts(with: H264Utilities.naluStartCode))
        } else {
            var length = UInt32(bytes.count - H264Utilities.naluStartCode.count).bigEndian
            bytes.withUnsafeBytes {
                XCTAssert(memcmp($0.baseAddress, &length, 4) == 0)
            }
        }
    }
}
