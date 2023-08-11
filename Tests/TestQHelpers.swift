import XCTest
@testable import Decimus

final class TestQHelpers: XCTestCase {
    func testSequentialObjectBlockingNameGate() throws {
        let namegate: SequentialObjectBlockingNameGate = .init()

        // 0,0 with no history should go through.
        XCTAssert(namegate.handle(groupId: UInt32.random(in: 0...UInt32.max), objectId: 0, lastGroup: nil, lastObject: nil))
        // Non 0 object ID with no history should not go through.
        XCTAssertFalse(namegate.handle(groupId: UInt32.random(in: 0...UInt32.max), objectId: UInt16.random(in: 1...UInt16.max), lastGroup: nil, lastObject: nil))

        // Sequential object in a group should go through.
        do {
            let currentGroup: UInt32 = .random(in: 0...UInt32.max)
            let currentObject: UInt16 = .random(in: 0...UInt16.max - 1)
            XCTAssert(namegate.handle(groupId: currentGroup, objectId: currentObject + 1, lastGroup: currentGroup, lastObject: currentObject))
        }

        // Non sequential object ID in a group should not go through.
        do {
            let currentGroup: UInt32 = .random(in: 0...UInt32.max)
            let currentObject: UInt16 = .random(in: 0...UInt16.max - 2)
            let new: UInt16 = .random(in: currentObject+2...UInt16.max)
            XCTAssertFalse(namegate.handle(groupId: currentGroup, objectId: new, lastGroup: currentGroup, lastObject: currentObject))
        }

        // Incrementing group jumps should go through when their objectId is 0.
        do {
            let currentGroup: UInt32 = .random(in: 0...UInt32.max - 2)
            let nextGroup: UInt32 = .random(in: currentGroup+1...UInt32.max-1)
            XCTAssert(namegate.handle(groupId: nextGroup, objectId: 0, lastGroup: currentGroup, lastObject: 0))
            // Even when it jumps non-sequentially.
            XCTAssert(namegate.handle(groupId: nextGroup + 1, objectId: 0, lastGroup: currentGroup, lastObject: 0))
            // Group jumps should not go through when their objectId is not 0.
            let nonZeroObject: UInt16 = .random(in: 1...UInt16.max)
            XCTAssertFalse(namegate.handle(groupId: nextGroup, objectId: nonZeroObject, lastGroup: currentGroup, lastObject: UInt16.random(in: 0...UInt16.max)))
        }
    }
}
