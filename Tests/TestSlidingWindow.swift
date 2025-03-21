// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

@Test("Test Sliding Window")
func testSlidingWindow() {
    let length: TimeInterval = 10
    let window = SlidingTimeWindow<Int>(length: length)
    let start = Date.now
    window.add(timestamp: start.addingTimeInterval(-length - 1), value: 1)
    window.add(timestamp: start.addingTimeInterval(-1), value: 2)
    window.add(timestamp: start, value: 3)
    #expect(window.get(from: start) == [2, 3])
}

private let vectors: [[TimeInterval]] = [
    [0.1, -0.11, 1, -1, -2],
    [-0.1, 0.11, 1, -1, -2],
    [0, 0.5, 1, -1, -2]
]

@Test("Closest to zero", arguments: vectors)
func testClosestToZero(values: [TimeInterval]) {
    #expect(values.closestToZero() == values[0])
}
