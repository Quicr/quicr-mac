@testable import Decimus
import CoreMedia
import AVFoundation
import XCTest

final class TestCMSampleBufferAttachments: XCTestCase {
    func testSetGet() throws {
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [],
                                        sampleSizes: [0])

        let groupId: UInt32 = 1
        try sample.setGroupId(groupId)
        XCTAssert(sample.getGroupId() == groupId)

        let objectId: UInt16 = 2
        try sample.setObjectId(objectId)
        XCTAssert(sample.getObjectId() == objectId)

        XCTAssertNil(sample.getSequenceNumber())
        let sequence: UInt64 = 3
        try sample.setSequenceNumber(sequence)
        XCTAssert(sample.getSequenceNumber() == sequence)

        XCTAssertNil(sample.getOrientation())
        let orientation: AVCaptureVideoOrientation = .portraitUpsideDown
        try sample.setOrientation(orientation)
        XCTAssert(sample.getOrientation() == orientation)

        XCTAssertNil(sample.getVerticalMirror())
        let mirror = false
        try sample.setVerticalMirror(mirror)
        XCTAssert(sample.getVerticalMirror() == mirror)

        XCTAssertNil(sample.getFPS())
        let fps: UInt8 = 30
        try sample.setFPS(fps)
        XCTAssert(sample.getFPS() == fps)
    }
}
