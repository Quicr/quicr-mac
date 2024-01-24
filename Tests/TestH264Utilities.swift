@testable import Decimus
import CoreMedia
import AVFoundation
import XCTest

final class TestH264Utilities: XCTestCase {
    func testDepacketization() throws {
        let values: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            1, 2, 3, 4, 5,
            0x00, 0x00, 0x00, 0x01,
            1, 8, 9, 10, 11
        ]
        let data = Data(values)
        var format: CMFormatDescription? = try .init(metadataFormatType: .h264)
        var orientation: AVCaptureVideoOrientation? = .portrait
        var mirror: Bool? = false
        guard let samples = try H264Utilities.depacketize(data,
                                                          groupId: 0,
                                                          objectId: 1,
                                                          format: &format,
                                                          orientation: &orientation,
                                                          verticalMirror: &mirror,
                                                          copy: true) else {
            XCTFail()
            return
        }
        XCTAssertEqual(samples.count, 2)

        // First 4 bytes should be big endian data length.
        let length = UInt32(5).bigEndian

        // Sample 1.
        let sample1 = samples[0]
        let dataBuffer1 = sample1.dataBuffer!
        XCTAssertEqual(dataBuffer1.dataLength, 9)
        let extractedData1: UnsafeMutableRawBufferPointer = .allocate(byteCount: dataBuffer1.dataLength,
                                                                      alignment: MemoryLayout<UInt8>.alignment)
        try dataBuffer1.copyDataBytes(to: extractedData1)
        values.withUnsafeBytes {
            var extractedLength: UInt32 = 0
            memcpy(&extractedLength, extractedData1.baseAddress, 4)
            XCTAssertEqual(length, extractedLength)
            XCTAssertEqual(0, memcmp(extractedData1.baseAddress?.advanced(by: 4),
                                     $0.baseAddress!.advanced(by: 4),
                                     dataBuffer1.dataLength - 4))
        }

        // Sample 2.
        let sample2 = samples[1]
        let dataBuffer2 = sample2.dataBuffer!
        XCTAssertEqual(dataBuffer2.dataLength, 9)
        let extractedData2: UnsafeMutableRawBufferPointer = .allocate(byteCount: dataBuffer2.dataLength,
                                                                      alignment: MemoryLayout<UInt8>.alignment)
        try dataBuffer2.copyDataBytes(to: extractedData2)
        values.withUnsafeBytes {
            XCTAssertEqual(0, memcmp(extractedData2.baseAddress! + 4,
                                     $0.baseAddress!.advanced(by: 9 + 4),
                                     dataBuffer2.dataLength))
        }
    }

    func testNaluDepacketize() throws {
        let values: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            1, 2, 3, 4, 5
        ]
        let format: CMFormatDescription = try .init(mediaType: .video, mediaSubType: .h264)
        var data = Data(values)
        let orientation: AVCaptureVideoOrientation = .portraitUpsideDown
        let mirror = true
        let groupId: UInt32 = 1
        let objectId: UInt16 = 2
        let sequence: UInt64? = 3
        let fps: UInt8? = 4
        let sample = try H264Utilities.depacketizeNalu(&data,
                                                       groupId: groupId,
                                                       objectId: objectId,
                                                       timeInfo: .init(),
                                                       format: format,
                                                       copy: false,
                                                       orientation: orientation,
                                                       verticalMirror: mirror,
                                                       sequenceNumber: sequence,
                                                       fps: fps)

        // Check the data is in the sample.
        XCTAssertNotNil(sample.dataBuffer)
        try sample.dataBuffer!.withUnsafeMutableBytes { depacketized in
            values.withUnsafeBytes { packetized in
                XCTAssertEqual(0,
                               memcmp(depacketized.baseAddress!.advanced(by: 4),
                                      packetized.baseAddress!.advanced(by: 4),
                                      values.count - 4))
            }
        }

        // Check attachments set.
        XCTAssert(sample.getGroupId() == groupId)
        XCTAssert(sample.getObjectId() == objectId)
        XCTAssert(sample.getSequenceNumber() == sequence)
        XCTAssert(sample.getOrientation() == orientation)
        XCTAssert(sample.getVerticalMirror() == mirror)
        XCTAssert(sample.getFPS() == fps)
    }

    func testGetTimestampBytes() {
        testGetTimestampBytes(startCode: true)
        testGetTimestampBytes(startCode: false)
    }

    func testGetTimestampBytes(startCode: Bool) {
        let time = CMTime(seconds: 1234, preferredTimescale: 5678)
        let bytes = H264Utilities.getTimestampSEIBytes(timestamp: time,
                                                       sequenceNumber: 1,
                                                       fps: 30,
                                                       startCode: startCode)
        XCTAssert(bytes.count == H264Utilities.timestampSEIBytes.count)
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
        let bytes = H264Utilities.getH264OrientationSEI(orientation: .portrait, verticalMirror: false, startCode: startCode)
        XCTAssert(bytes.count == H264Utilities.orientationSei.count)
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
