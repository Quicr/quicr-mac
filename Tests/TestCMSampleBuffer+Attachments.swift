@testable import Decimus
import CoreMedia
import AVFoundation
import XCTest

final class TestCMSampleBufferAttachments: XCTestCase {
    func testSetGet() throws {
        var sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [],
                                        sampleSizes: [0])

        let groupId: UInt32 = 1
        sample.setGroupId(groupId)
        XCTAssert(sample.getGroupId() == groupId)

        let objectId: UInt16 = 2
        sample.setObjectId(objectId)
        XCTAssert(sample.getObjectId() == objectId)

        XCTAssertNil(sample.getSequenceNumber())
        let sequence: UInt64 = 3
        sample.setSequenceNumber(sequence)
        XCTAssert(sample.getSequenceNumber() == sequence)

        XCTAssertNil(sample.getOrientation())
        let orientation: AVCaptureVideoOrientation = .portraitUpsideDown
        sample.setOrientation(orientation)
        XCTAssert(sample.getOrientation() == orientation)

        XCTAssertNil(sample.getVerticalMirror())
        let mirror = false
        sample.setVerticalMirror(mirror)
        XCTAssert(sample.getVerticalMirror() == mirror)

        XCTAssertNil(sample.getFPS())
        let fps: UInt8 = 30
        sample.setFPS(fps)
        XCTAssert(sample.getFPS() == fps)
    }
}
