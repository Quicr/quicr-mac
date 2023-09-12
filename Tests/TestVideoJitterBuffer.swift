import XCTest
@testable import Decimus

final class TestVideoJitterBuffer: XCTestCase {

    /// Nothing should be returned until the min depth has been exceeded.
    func TestPlayout() {
        testPlayout(sort: true)
        testPlayout(sort: false)
    }

    func testPlayout(sort: Bool) {
        let buffer: VideoJitterBuffer = .init(namespace: .init(),
                                              frameDuration: 1 / 30,
                                              minDepth: 1/30 * 2.5,
                                              metricsSubmitter: nil,
                                              sort: sort)
        
        // Write 1, no play.
        let frame1: VideoFrame = .init(groupId: 0, objectId: 0, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame1))
        XCTAssertNil(buffer.read())
        
        // Write 2, no play.
        let frame2: VideoFrame = .init(groupId: 0, objectId: 1, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame2))
        XCTAssertNil(buffer.read())
        
        // Write 3, play, get 1.
        let frame3: VideoFrame = .init(groupId: 0, objectId: 2, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame3))
        XCTAssertEqual(frame1, buffer.read())
        
        // Write 4, get 2.
        let frame4: VideoFrame = .init(groupId: 0, objectId: 3, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame4))
        XCTAssertEqual(frame2, buffer.read())
        
        // Get 3, 4 and done.
        XCTAssertEqual(frame3, buffer.read())
        XCTAssertEqual(frame4, buffer.read())
        XCTAssertNil(buffer.read())
    }
    
    // Out of orders should go in order.
    func testOutOfOrder() {
        let buffer: VideoJitterBuffer = .init(namespace: .init(),
                                              frameDuration: 1 / 30,
                                              minDepth: 0,
                                              metricsSubmitter: nil,
                                              sort: true)
        
        // Write newer.
        let frame2: VideoFrame = .init(groupId: 0, objectId: 1, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame2))
        
        // Write older.
        let frame1: VideoFrame = .init(groupId: 0, objectId: 0, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame1))
        
        // Get older first.
        let read1 = buffer.read()
        XCTAssertEqual(frame1, read1)
        
        // Then newer.
        let read2 = buffer.read()
        XCTAssertEqual(frame2, read2)
    }

    // Out of orders should not be allowed past a read.
    func testOlderFrame() {
        testOlderFrame(true)
        testOlderFrame(false)
    }

    func testOlderFrame(_ sort: Bool) {
        let buffer: VideoJitterBuffer = .init(namespace: .init(),
                                              frameDuration: 1 / 30,
                                              minDepth: 0,
                                              metricsSubmitter: nil,
                                              sort: sort)

        // Write newer.
        let frame2: VideoFrame = .init(groupId: 0, objectId: 1, data: .init())
        XCTAssertTrue(buffer.write(videoFrame: frame2))

        // Read newer.
        let read1 = buffer.read()
        XCTAssertEqual(frame2, read1)

        // Write older should fail.
        let frame1: VideoFrame = .init(groupId: 0, objectId: 0, data: .init())
        XCTAssertFalse(buffer.write(videoFrame: frame1))
    }
}
