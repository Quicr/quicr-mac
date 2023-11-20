import CoreMedia
import XCTest
@testable import Decimus

final class TestVideoJitterBuffer: XCTestCase {

    /// Nothing should be returned until the min depth has been exceeded.
    func TestPlayout() throws {
        try testPlayout(sort: true)
        try testPlayout(sort: false)
    }
    
    func exampleSample(groupId: UInt32,
                       objectId: UInt16,
                       sequenceNumber: UInt64,
                       fps: UInt8) -> [CMSampleBuffer] {
        let sample = try! CMSampleBuffer(dataBuffer: nil, formatDescription: nil, numSamples: 1, sampleTimings: [], sampleSizes: [])
        sample.setGroupId(groupId)
        sample.setObjectId(objectId)
        sample.setSequenceNumber(sequenceNumber)
        sample.setFPS(fps)
        return [sample]
    }

    func testPlayout(sort: Bool) throws {
        let buffer: VideoJitterBuffer = .init(namespace: .init(),
                                              frameDuration: 1 / 30,
                                              metricsSubmitter: nil,
                                              sort: sort,
                                              minDepth: 1/30 * 2.5)

        // Write 1, no play.
        let frame1: VideoFrame = try .init( samples: exampleSample(groupId: 0,
                                                                   objectId: 0,
                                                                   sequenceNumber: 0,
                                                                   fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame1))
        XCTAssertNil(buffer.read())

        // Write 2, no play.
        let frame2: VideoFrame = try .init( samples: exampleSample(groupId: 0,
                                                                   objectId: 1,
                                                                   sequenceNumber: 1,
                                                                   fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame2))
        XCTAssertNil(buffer.read())

        // Write 3, play, get 1.
        let frame3: VideoFrame = try .init(samples: exampleSample(groupId: 0,
                                                                  objectId: 2,
                                                                  sequenceNumber: 2,
                                                                  fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame3))
        XCTAssertEqual(frame1, buffer.read())

        // Write 4, get 2.
        let frame4: VideoFrame = try .init(samples: exampleSample(groupId: 0,
                                                                  objectId: 3,
                                                                  sequenceNumber: 3,
                                                                  fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame4))
        XCTAssertEqual(frame2, buffer.read())

        // Get 3, 4 and done.
        XCTAssertEqual(frame3, buffer.read())
        XCTAssertEqual(frame4, buffer.read())
        XCTAssertNil(buffer.read())
    }

    // Out of orders should go in order.
    func testOutOfOrder() throws {
        let buffer: VideoJitterBuffer = .init(namespace: .init(),
                                              frameDuration: 1 / 30,
                                              metricsSubmitter: nil,
                                              sort: true,
                                              minDepth: 0)

        // Write newer.
        let frame2: VideoFrame = try .init(samples: exampleSample(groupId: 0,
                                                                  objectId: 1,
                                                                  sequenceNumber: 1,
                                                                  fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame2))

        // Write older.
        let frame1: VideoFrame = try .init(samples: exampleSample(groupId: 0,
                                                                  objectId: 0,
                                                                  sequenceNumber: 0,
                                                                  fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame1))

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
        let buffer: VideoJitterBuffer = .init(namespace: .init(),
                                              frameDuration: 1 / 30,
                                              metricsSubmitter: nil,
                                              sort: sort,
                                              minDepth: 0)

        // Write newer.
        let frame2: VideoFrame = try .init(samples: exampleSample(groupId: 0,
                                                                  objectId: 1,
                                                                  sequenceNumber: 1,
                                                                  fps: 30))
        XCTAssertTrue(buffer.write(videoFrame: frame2))

        // Read newer.
        let read1 = buffer.read()
        XCTAssertEqual(frame2, read1)

        // Write older should fail.
        let frame1: VideoFrame = try .init(samples: exampleSample(groupId: 0,
                                                                  objectId: 0,
                                                                  sequenceNumber: 0,
                                                                  fps: 30))
        XCTAssertFalse(buffer.write(videoFrame: frame1))
    }

    func testIntervalCalculations() {
        let minDepth: TimeInterval = 0.2
        let duration: TimeInterval = 1 / 30
        let firstWriteTime: Date = .now
        let interval: IntervalDequeuer = .init(minDepth: minDepth, frameDuration: duration, firstWriteTime: firstWriteTime)
        // At first write, and no dequeued frames, we should wait min depth.
        XCTAssertEqual(interval.calculateWaitTime(from: .now), minDepth, accuracy: 1 / 1000)

        // Dequeued N, should be minDepth + frameDuration from "now".
        interval.dequeuedCount = .random(in: UInt.min...20000)
        let doubleCount: Double = .init(interval.dequeuedCount)
        XCTAssertEqual(interval.calculateWaitTime(from: firstWriteTime),
                       minDepth + (doubleCount * duration),
                       accuracy: 1 / 1000)

        // If we query the time at the expected time, should be 0.
        XCTAssertEqual(interval.calculateWaitTime(from: firstWriteTime + (minDepth + (doubleCount * duration))),
                                                  0,
                                                  accuracy: 1 / 1000)

        // If we query the time past the time, should be negative by that much.
        let offset: TimeInterval = .random(in: 0.01...1000)
        XCTAssertEqual(interval.calculateWaitTime(from: firstWriteTime + (minDepth + (doubleCount * duration) + offset)),
                       -offset,
                       accuracy: 1/1000)
    }
}
