import XCTest
@testable import Decimus

final class TestQHelpers: XCTestCase {
    func SequentialObjectBlockingNameGate() {
        let namegate: SequentialObjectBlockingNameGate = .init()
        
        // MARK: Positive cases.
        
        // 0,0 with no history should go through.
        XCTAssert(namegate.handle(groupId: 0, objectId: 0, lastGroup: nil, lastObject: nil))
        // Incremental object in a group should go through.
        XCTAssert(namegate.handle(groupId: 0, objectId: 1, lastGroup: 0, lastObject: 0))
        // Group jumps should go through when their objectId is 0.
        XCTAssert(namegate.handle(groupId: 1, objectId: 0, lastGroup: 0, lastObject: 1))
        // Even when it jumps non-sequentially.
        XCTAssert(namegate.handle(groupId: 2, objectId: 0, lastGroup: 0, lastObject: 1))
        
        // MARK: Negative cases.
        
        // Non 0 object ID with no history should not go through.
        XCTAssertFalse(namegate.handle(groupId: 0, objectId: 1, lastGroup: nil, lastObject: nil))
    }
}
