// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import CoreMedia
import XCTest

final class TestVideoUtilities: XCTestCase {
    func testH264Depacketization() throws {
        try self.testDepacketization(H264Utilities())
        try self.testLengthDepacketization(H264Utilities())
    }

    func testHEVCDepacketization() throws {
        try self.testDepacketization(HEVCUtilities())
        try self.testLengthDepacketization(HEVCUtilities())
    }

    func testLengthDepacketization(_ utilities: VideoUtilities) throws {
        let values: [UInt8] = [
            0x00, 0x00, 0x00, 0x05,
            1, 2, 3, 4, 5,
            0x00, 0x00, 0x00, 0x06,
            1, 8, 9, 10, 11, 12
        ]
        let data = Data(values)
        var format: CMFormatDescription? = try .init(metadataFormatType: .h264)
        let callback: (Data) -> Void = { _ in }
        guard let samples = try utilities.depacketize(data,
                                                      format: &format,
                                                      copy: true,
                                                      seiCallback: callback) else {
            XCTFail()
            return
        }
        XCTAssertEqual(samples.count, 2)

        // First 4 bytes should be big endian data length.
        let length = UInt32(5).bigEndian

        // Sample 1.
        let dataBuffer1 = samples[0]
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
        let dataBuffer2 = samples[1]
        XCTAssertEqual(dataBuffer2.dataLength, 10)
        let extractedData2: UnsafeMutableRawBufferPointer = .allocate(byteCount: dataBuffer2.dataLength,
                                                                      alignment: MemoryLayout<UInt8>.alignment)
        try dataBuffer2.copyDataBytes(to: extractedData2)
        values.withUnsafeBytes {
            XCTAssertEqual(0, memcmp(extractedData2.baseAddress! + 4,
                                     $0.baseAddress!.advanced(by: 9 + 4),
                                     dataBuffer2.dataLength))
        }
    }

    func testDepacketization(_ utilities: VideoUtilities) throws {
        let values: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            1, 2, 3, 4, 5,
            0x00, 0x00, 0x00, 0x01,
            1, 8, 9, 10, 11
        ]
        let data = Data(values)
        var format: CMFormatDescription? = try .init(metadataFormatType: .h264)
        let callback: (Data) -> Void = { _ in }
        guard let samples = try utilities.depacketize(data,
                                                      format: &format,
                                                      copy: true,
                                                      seiCallback: callback) else {
            XCTFail()
            return
        }
        XCTAssertEqual(samples.count, 2)

        // First 4 bytes should be big endian data length.
        let length = UInt32(5).bigEndian

        // Sample 1.
        let dataBuffer1 = samples[0]
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
        let dataBuffer2 = samples[1]
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

    func testBuildSampleBuffer() throws {
        let values: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            1, 2, 3, 4, 5
        ]
        try values.withUnsafeBytes { packetized in
            let block = try H264Utilities.buildBlockBuffer(packetized, copy: false)

            // Check the data is in the buffer.
            XCTAssertNotNil(block)
            try block.withUnsafeMutableBytes { depacketized in
                XCTAssertEqual(0,
                               memcmp(depacketized.baseAddress!.advanced(by: 4),
                                      packetized.baseAddress!.advanced(by: 4),
                                      values.count - 4))
            }
        }
    }
}

extension TestVideoUtilities {
    @MainActor
    func testLOCVideoConfigReception() async throws {
        let fixture = try TopNH264Fixture.loadFromTestBundle()
        var format: CMFormatDescription?
        let buffers = try XCTUnwrap(H264Utilities().depacketize(fixture.accessUnits[0].payload,
                                                                format: &format,
                                                                copy: true,
                                                                seiCallback: { _ in }))
        let config = try XCTUnwrap(H264Utilities.extractAVCCAtom(from: XCTUnwrap(format)))

        for (annexB, timescale) in [(false, UInt64?.none), (true, nil), (false, 90_000)] {
            var payload = Data()
            for buffer in buffers {
                var bytes = Data(count: buffer.dataLength)
                try bytes.withUnsafeMutableBytes { try buffer.copyDataBytes(to: $0) }
                if annexB {
                    bytes.replaceSubrange(0..<4, with: H264Utilities.naluStartCode)
                }
                payload.append(bytes)
            }
            let decoded = expectation(description: "Decode LOC header config, Annex B: \(annexB)")
            let handler = try VideoHandler(fullTrackName: .init(namespace: ["loc-test"], name: "video"),
                                           config: .init(codec: .h264, bitrate: 1_000_000, fps: fixture.fps,
                                                         width: Int32(fixture.width), height: Int32(fixture.height),
                                                         bitrateType: .average),
                                           participants: .init(),
                                           metricsSubmitter: nil,
                                           videoBehaviour: .freeze,
                                           granularMetrics: false,
                                           jitterBufferConfig: .init(),
                                           simulreceive: .none,
                                           variances: .init(expectedOccurrences: 0),
                                           participantId: .init(1),
                                           subscribeDate: .now,
                                           joinDate: .now,
                                           activeSpeakerStats: nil,
                                           handlerConfig: .init(calculateLatency: false, mediaInterop: false,
                                                                decodeBufferSize: 1),
                                           wifiDetector: nil,
                                           videoPipelineEvent: { event in
                                            if case .decoderOutput(let seconds) = event.kind {
                                                if timescale != nil { XCTAssertEqual(seconds, 1.5) }
                                                decoded.fulfill()
                                            }
                                           })
            var headers = HeaderExtensions()
            if let timescale {
                try headers.setHeader(.timestamp(135_000))
                try headers.setHeader(.timescale(timescale))
            } else {
                try headers.setHeader(.captureTimestamp(.now))
            }
            try headers.setHeader(.videoConfig(config))
            handler.objectReceived(.init(groupId: 0, subgroupId: 0, objectId: 0,
                                         payloadLength: UInt64(payload.count), status: .available,
                                         priority: nil, ttl: nil),
                                   data: payload, extensions: headers, when: .now, cached: false, drop: false)
            await fulfillment(of: [decoded], timeout: 5)
            handler.stop()
        }
    }
}
