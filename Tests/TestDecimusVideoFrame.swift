// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import Decimus
import XCTest
import CoreMedia

final class TestDecimusVideoFrame: XCTestCase {
    func testCopyConstruct() throws {
        // Setup original data.
        let count = 10
        let value: UInt8 = 255
        var deallocate = true
        let originalData = UnsafeMutableRawBufferPointer.allocate(byteCount: count,
                                                                  alignment: MemoryLayout<UInt8>.alignment)
        defer {
            if deallocate {
                originalData.deallocate()
            }
        }
        memset(originalData.baseAddress, Int32(value), originalData.count)
        let originalBlockBuffer = try CMBlockBuffer(buffer: originalData) { _, _ in }
        let originalFormat = try CMFormatDescription(mediaType: .video, mediaSubType: .h264)
        let originalSampleBuffer = try CMSampleBuffer(dataBuffer: originalBlockBuffer,
                                                      formatDescription: originalFormat,
                                                      numSamples: 1,
                                                      sampleTimings: [.invalid],
                                                      sampleSizes: [originalData.count])
        let now = Date.now
        let original = DecimusVideoFrame(samples: [originalSampleBuffer],
                                         groupId: 1,
                                         objectId: 2,
                                         sequenceNumber: 3,
                                         fps: 4,
                                         orientation: .portrait,
                                         verticalMirror: true)

        // Create deep copy.
        let copied = try DecimusVideoFrame(copy: original)

        // Now deallocate original memory.
        memset(originalData.baseAddress, 0, originalData.count)
        originalData.deallocate()
        deallocate = false

        // Now query all properites and compare.
        XCTAssertEqual(copied.groupId, original.groupId)
        XCTAssertEqual(copied.objectId, original.objectId)
        XCTAssertEqual(copied.sequenceNumber, original.sequenceNumber)
        XCTAssertEqual(copied.fps, original.fps)
        XCTAssertEqual(copied.orientation, original.orientation)
        XCTAssertEqual(copied.verticalMirror, original.verticalMirror)

        let first = copied.samples.first
        XCTAssertNotNil(first)

        // Compare the format.
        XCTAssertEqual(first?.formatDescription, originalFormat)

        // Compare with the original memory.
        let copiedBuffer = first!.dataBuffer
        XCTAssertNotNil(copiedBuffer)
        let data = Data(repeating: value, count: count)
        try data.withUnsafeBytes { expected in
            try copiedBuffer!.withContiguousStorage { actual in
                XCTAssertEqual(memcmp(expected.baseAddress, actual.baseAddress, count), 0)
            }
        }
    }
}
