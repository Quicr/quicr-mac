@testable import Decimus
import Foundation
import XCTest
import CoreMedia

final class TestApplicationH264SEIs: XCTestCase {
    func testGetTimestampBytes() {
        testGetTimestampBytes(startCode: true)
        testGetTimestampBytes(startCode: false)
    }
    
    func testGetTimestampBytes(startCode: Bool) {
        let time = CMTime(seconds: 1234, preferredTimescale: 5678)
        let bytes = ApplicationH264SEIs.getTimestampSEIBytes(timestamp: time,
                                                       sequenceNumber: 1,
                                                       fps: 30,
                                                       startCode: startCode)
        XCTAssert(bytes.count == ApplicationH264SEIs.timestampSEIBytes.count)
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
        testGetOrientationBytes(startCode: true)
        testGetOrientationBytes(startCode: false)
    }
    
    func testGetOrientationBytes(startCode: Bool) {
        let bytes = ApplicationH264SEIs.getH264OrientationSEI(orientation: .portrait, verticalMirror: false, startCode: startCode)
        XCTAssert(bytes.count == ApplicationH264SEIs.orientationSei.count)
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
