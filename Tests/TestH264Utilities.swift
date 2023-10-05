@testable import Decimus
import CoreMedia
import XCTest

final class TestH264Utilities: XCTestCase {
    func testDepacketization() throws {
        let values: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            1,2,3,4,5,
            0x00, 0x00, 0x00, 0x01,
            1,8,9,10,11,
        ]
        var data = Data(values)
        var format: CMFormatDescription? = try .init(metadataFormatType: .h264)
        let samples = try H264Utilities.depacketize(&data, timeInfo: .init(), format: &format) { _ in
            XCTFail()
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
        try! dataBuffer1.copyDataBytes(to: extractedData1)
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
        try! dataBuffer2.copyDataBytes(to: extractedData2)
        values.withUnsafeBytes {
            XCTAssertEqual(0, memcmp(extractedData2.baseAddress! + 4,
                                     $0.baseAddress!.advanced(by: 9 + 4),
                                     dataBuffer2.dataLength))
        }
    }
    
    func testNaluDepacketize() throws {
        let values: [UInt8] = [
            0x00,0x00,0x00,0x01,
            1,2,3,4,5
        ]
        let format: CMFormatDescription = try .init(mediaType: .video, mediaSubType: .h264)
        var data = Data(values)
        let sample = try H264Utilities.depacketizeNalu(&data, timeInfo: .init(), format: format)
        
        XCTAssertNotNil(sample.dataBuffer)
        try sample.dataBuffer!.withUnsafeMutableBytes { depacketized in
            values.withUnsafeBytes { packetized in
                XCTAssertEqual(0,
                               memcmp(depacketized.baseAddress!.advanced(by: 4),
                                      packetized.baseAddress!.advanced(by: 4),
                                      values.count - 4))
            }
        }
    }
}