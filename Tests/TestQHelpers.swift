// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import Decimus

final class TestQHelpers: XCTestCase {
    func testSequentialObjectBlockingNameGate() throws {
        let namegate: SequentialObjectBlockingNameGate = .init()

        // 0,0 with no history should go through.
        XCTAssert(namegate.handle(groupId: UInt64.random(in: 0...UInt64.max),
                                  objectId: 0,
                                  lastGroup: nil,
                                  lastObject: nil))
        // Non 0 object ID with no history should not go through.
        XCTAssertFalse(namegate.handle(groupId: UInt64.random(in: 0...UInt64.max),
                                       objectId: UInt64.random(in: 1...UInt64.max),
                                       lastGroup: nil,
                                       lastObject: nil))

        // Sequential object in a group should go through.
        do {
            let currentGroup: UInt64 = .random(in: 0...UInt64.max)
            let currentObject: UInt64 = .random(in: 0...UInt64.max - 1)
            XCTAssert(namegate.handle(groupId: currentGroup,
                                      objectId: currentObject + 1,
                                      lastGroup: currentGroup,
                                      lastObject: currentObject))
            // Sequential objects in a different group should not go through.
            var differentGroup: UInt64
            repeat {
                differentGroup = .random(in: 0...UInt64.max)
            }
            while differentGroup == currentGroup
            XCTAssertFalse(namegate.handle(groupId: differentGroup,
                                           objectId: currentObject + 1,
                                           lastGroup: currentGroup,
                                           lastObject: currentObject))
        }

        // Non sequential object ID in a group should not go through.
        do {
            let currentGroup: UInt64 = .random(in: 0...UInt64.max)
            let currentObject: UInt64 = .random(in: 0...UInt64.max - 2)
            let new: UInt64 = .random(in: currentObject+2...UInt64.max)
            XCTAssertFalse(namegate.handle(groupId: currentGroup,
                                           objectId: new,
                                           lastGroup: currentGroup,
                                           lastObject: currentObject))
        }

        // Incrementing group jumps should go through when their objectId is 0.
        do {
            let currentGroup: UInt64 = .random(in: 0...UInt64.max - 2)
            let nextGroup: UInt64 = .random(in: currentGroup+1...UInt64.max-1)
            XCTAssert(namegate.handle(groupId: nextGroup, objectId: 0, lastGroup: currentGroup, lastObject: 0))
            // Even when it jumps non-sequentially.
            XCTAssert(namegate.handle(groupId: nextGroup + 1, objectId: 0, lastGroup: currentGroup, lastObject: 0))
            // Group jumps should not go through when their objectId is not 0.
            let nonZeroObject: UInt64 = .random(in: 1...UInt64.max)
            XCTAssertFalse(namegate.handle(groupId: nextGroup,
                                           objectId: nonZeroObject,
                                           lastGroup: currentGroup,
                                           lastObject: UInt64.random(in: 0...UInt64.max)))
        }

        // Example series.
        XCTAssertTrue(namegate.handle(groupId: 0, objectId: 0, lastGroup: nil, lastObject: nil))
        XCTAssertTrue(namegate.handle(groupId: 0, objectId: 1, lastGroup: 0, lastObject: 0))
        XCTAssertTrue(namegate.handle(groupId: 0, objectId: 2, lastGroup: 0, lastObject: 1))
        XCTAssertTrue(namegate.handle(groupId: 0, objectId: 3, lastGroup: 0, lastObject: 2))
        XCTAssertFalse(namegate.handle(groupId: 0, objectId: 5, lastGroup: 0, lastObject: 3))
        XCTAssertTrue(namegate.handle(groupId: 0, objectId: 4, lastGroup: 0, lastObject: 3))
        XCTAssertFalse(namegate.handle(groupId: 0, objectId: 6, lastGroup: 0, lastObject: 4))
        XCTAssertFalse(namegate.handle(groupId: 0, objectId: 7, lastGroup: 0, lastObject: 4))
    }
}
