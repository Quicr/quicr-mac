import CoreMedia
import XCTest
@testable import Decimus

extension DecimusVideoFrame: Equatable {
    public static func == (lhs: Decimus.DecimusVideoFrame, rhs: Decimus.DecimusVideoFrame) -> Bool {
        lhs.samples == rhs.samples &&
            lhs.groupId == rhs.groupId &&
            lhs.objectId == rhs.objectId &&
            lhs.sequenceNumber == rhs.sequenceNumber &&
            lhs.fps == rhs.fps &&
            lhs.orientation == rhs.orientation &&
            lhs.verticalMirror == rhs.verticalMirror
    }
}

final class TestVideoJitterBuffer: XCTestCase {

    /// Nothing should be returned until the min depth has been exceeded.
    func doTestPlayout() throws {
        try testPlayout(sort: true)
        try testPlayout(sort: false)
    }

    func exampleSample(groupId: UInt32,
                       objectId: UInt16,
                       sequenceNumber: UInt64,
                       fps: UInt8) throws -> DecimusVideoFrame {
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [],
                                        sampleSizes: [])
        return .init(samples: [sample],
                     groupId: groupId,
                     objectId: objectId,
                     sequenceNumber: sequenceNumber,
                     fps: fps,
                     orientation: nil,
                     verticalMirror: nil,
                     captureDate: .now)
    }

    func testPlayout(sort: Bool) throws {
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: sort,
                                           minDepth: 1/30 * 2.5,
                                           capacity: 4)

        // Write 1, no play.
        let frame1 = try exampleSample(groupId: 0,
                                       objectId: 0,
                                       sequenceNumber: 0,
                                       fps: 30)
        try buffer.write(videoFrame: frame1)
        XCTAssertNil(buffer.read())

        // Write 2, no play.
        let frame2 = try exampleSample(groupId: 0,
                                       objectId: 1,
                                       sequenceNumber: 1,
                                       fps: 30)
        try buffer.write(videoFrame: frame2)
        XCTAssertNil(buffer.read())

        // Write 3, play, get 1.
        let frame3 = try exampleSample(groupId: 0,
                                       objectId: 2,
                                       sequenceNumber: 2,
                                       fps: 30)
        try buffer.write(videoFrame: frame3)
        XCTAssertEqual(frame1, buffer.read())

        // Write 4, get 2.
        let frame4 = try exampleSample(groupId: 0,
                                       objectId: 3,
                                       sequenceNumber: 3,
                                       fps: 30)
        try buffer.write(videoFrame: frame4)
        XCTAssertEqual(frame2, buffer.read())

        // Get 3, 4 and done.
        XCTAssertEqual(frame3, buffer.read())
        XCTAssertEqual(frame4, buffer.read())
        XCTAssertNil(buffer.read())
    }

    // Out of orders should go in order.
    func testOutOfOrder() throws {
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: true,
                                           minDepth: 0,
                                           capacity: 2)

        // Write newer.
        let frame2 = try exampleSample(groupId: 0,
                                       objectId: 1,
                                       sequenceNumber: 1,
                                       fps: 30)
        try buffer.write(videoFrame: frame2)

        // Write older.
        let frame1 = try exampleSample(groupId: 0,
                                       objectId: 0,
                                       sequenceNumber: 0,
                                       fps: 30)
        try buffer.write(videoFrame: frame1)

        // Get older first.
        let read1 = buffer.read()
        XCTAssertEqual(frame1, read1)

        // Then newer.
        let read2 = buffer.read()
        XCTAssertEqual(frame2, read2)
    }

    // Out of orders should not be allowed past a read.
    func testOlderFrame() throws {
        try testOlderFrame(true)
        try testOlderFrame(false)
    }

    func testOlderFrame(_ sort: Bool) throws {
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: sort,
                                           minDepth: 0,
                                           capacity: 2)

        // Write newer.
        let frame2 = try exampleSample(groupId: 0,
                                       objectId: 1,
                                       sequenceNumber: 1,
                                       fps: 30)
        try buffer.write(videoFrame: frame2)

        // Read newer.
        let read1 = buffer.read()
        XCTAssertEqual(frame2, read1)

        // Write older should fail.
        let frame1 = try exampleSample(groupId: 0,
                                       objectId: 0,
                                       sequenceNumber: 0,
                                       fps: 30)
        XCTAssertThrowsError(try buffer.write(videoFrame: frame1)) {
            XCTAssertEqual("Refused enqueue as older than last read", $0 as? String)
        }
    }

    func testWaitTimeNoDate() throws {
        let startTime: Date = .now
        var waitTime: TimeInterval?
        let minDepth: TimeInterval = 0.2
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: minDepth,
                                           capacity: 1)

        // No calculation possible with no frame available.
        waitTime = buffer.calculateWaitTime(from: startTime, offset: 0)
        XCTAssertNil(waitTime)
    }

    func testWaitTimeMinDepth() throws {
        let startTime: Date = .now
        var waitTime: TimeInterval?
        let minDepth: TimeInterval = 0.2
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: minDepth,
                                           capacity: 1)

        // At first write, and otherwise on time, we should wait the min depth.
        let presentation = CMTime(value: CMTimeValue(Date.timeIntervalSinceReferenceDate), timescale: 1)
        let diff = startTime.timeIntervalSinceReferenceDate - presentation.seconds
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [
                                            .init(duration: .init(value: 1,
                                                                  timescale: 30),
                                                  presentationTimeStamp: presentation,
                                                  decodeTimeStamp: .invalid)
                                        ],
                                        sampleSizes: [0])
        let frame = DecimusVideoFrame(samples: [sample],
                                      groupId: 1,
                                      objectId: 1,
                                      sequenceNumber: 1,
                                      fps: 1,
                                      orientation: nil,
                                      verticalMirror: nil,
                                      captureDate: .now)
        try buffer.write(videoFrame: frame)
        waitTime = buffer.calculateWaitTime(from: startTime, offset: diff)
        XCTAssertNotNil(waitTime)
        XCTAssertEqual(minDepth, waitTime!, accuracy: 1 / 1000)
    }

    func testWaitTimeN() throws {
        let startTime: Date = .now
        let minDepth: TimeInterval = 0.2
        let buffer = try VideoJitterBuffer(namespace: .init(),
                                           metricsSubmitter: nil,
                                           sort: false,
                                           minDepth: minDepth,
                                           capacity: 2)
        let presentation = CMTime(value: CMTimeValue(startTime.timeIntervalSinceReferenceDate), timescale: 1)
        var diff: TimeInterval?
        let duration = CMTime(value: 1, timescale: 30)

        for count in 0..<2 {
            if diff == nil {
                diff = startTime.timeIntervalSinceReferenceDate - presentation.seconds
            }
            let adjust = CMTimeMultiply(duration, multiplier: Int32(count))
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [
                                                .init(duration: duration,
                                                      presentationTimeStamp: CMTimeAdd(presentation, adjust),
                                                      decodeTimeStamp: .invalid)
                                            ],
                                            sampleSizes: [0])
            let frame = DecimusVideoFrame(samples: [sample],
                                          groupId: 1,
                                          objectId: 1,
                                          sequenceNumber: 1,
                                          fps: 1,
                                          orientation: nil,
                                          verticalMirror: nil,
                                          captureDate: .now)
            try buffer.write(videoFrame: frame)
        }

        // There are 2 frames in the buffer. If we have waited min depth, first should be 0.
        let waitTime = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth), offset: diff!)
        XCTAssertNotNil(waitTime)
        print(waitTime!)
        XCTAssertEqual(0, waitTime!, accuracy: 1 / 1000)

        // If we read this first one, next should be a duration away.
        let read = buffer.read()
        XCTAssertNotNil(read)
        let firstReadWait = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth), offset: diff!)
        XCTAssertNotNil(firstReadWait)
        XCTAssertEqual(duration.seconds, firstReadWait!, accuracy: 1 / 1000)

        // Any time we take (less than a frame duration here) should proportionally decrease the wait.
        let later = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth).addingTimeInterval(duration.seconds / 2), offset: diff!)
        XCTAssertNotNil(later)
        XCTAssertEqual(duration.seconds / 2, later!, accuracy: 1 / 1000)

        // If we wait too long, say 1.5 durations, we should get negative 1/2 duration.
        let negativeWait = buffer.calculateWaitTime(from: startTime.addingTimeInterval(minDepth).addingTimeInterval(duration.seconds * 1.5), offset: diff!)
        XCTAssertNotNil(negativeWait)
        XCTAssertEqual(-duration.seconds / 2, negativeWait!, accuracy: 1 / 1000)
    }
}
