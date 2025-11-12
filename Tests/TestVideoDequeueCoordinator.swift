// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

class MockDequeueHandler: DequeueSchedulable {
    let dequeueIdentifier: String
    var processCount = 0
    var deadlines: [Ticks] = []
    var shouldFail = false

    init(identifier: String, deadlines: [Ticks]) {
        self.dequeueIdentifier = identifier
        self.deadlines = deadlines
    }

    func calculateNextDeadline(from: Ticks) -> Ticks? {
        guard !self.deadlines.isEmpty else { return nil }
        return self.deadlines.removeFirst()
    }

    func processFrame(at: Ticks) throws -> Bool {
        self.processCount += 1
        if self.shouldFail {
            throw "Test error"
        }
        return true
    }
}

@Suite("VideoDequeueCoordinator Tests", .serialized)
struct VideoDequeueCoordinatorTests {

    @Test("Single handler processes frames")
    func testSingleHandler() async throws {
        let coordinator = VideoDequeueCoordinator.shared

        let now = Ticks.now
        let handler = MockDequeueHandler(
            identifier: "test1",
            deadlines: [
                now.addingTimeInterval(0.010), // +10ms
                now.addingTimeInterval(0.020)  // +20ms
            ]
        )

        coordinator.register(handler)

        // Wait for first frame
        try await Task.sleep(for: .milliseconds(15))
        #expect(handler.processCount >= 1)

        // Wait for second frame
        try await Task.sleep(for: .milliseconds(15))
        #expect(handler.processCount >= 2)

        coordinator.unregister(handler.dequeueIdentifier)
    }

    @Test("Multiple handlers process independently")
    func testMultipleHandlers() async throws {
        let coordinator = VideoDequeueCoordinator.shared

        let now = Ticks.now
        let deadline1 = now.addingTimeInterval(0.010)
        let deadline2 = now.addingTimeInterval(0.050)

        print("Test time: \(now), deadline1: \(deadline1), deadline2: \(deadline2)")
        print("Deadline1 offset: \(deadline1.timeIntervalSince(now))s")
        print("Deadline2 offset: \(deadline2.timeIntervalSince(now))s")

        let handler1 = MockDequeueHandler(
            identifier: "test_multi_1",
            deadlines: [deadline1]
        )
        let handler2 = MockDequeueHandler(
            identifier: "test_multi_2",
            deadlines: [deadline2]
        )

        coordinator.register(handler1)
        coordinator.register(handler2)

        // Give registration time to complete, then wait for first handler
        try await Task.sleep(for: .milliseconds(25))
        #expect(handler1.processCount == 1)
        #expect(handler2.processCount == 0)

        // Wait for second handler
        try await Task.sleep(for: .milliseconds(35))
        #expect(handler2.processCount == 1)

        coordinator.unregister(handler1.dequeueIdentifier)
        coordinator.unregister(handler2.dequeueIdentifier)
    }

    @Test("Batching with similar deadlines")
    func testBatching() async throws {
        let coordinator = VideoDequeueCoordinator.shared

        let now = Ticks.now
        let baseDeadline = now.addingTimeInterval(0.010)

        // Create 3 handlers with deadlines within 1ms
        let handlers = (0..<3).map { index in
            MockDequeueHandler(
                identifier: "test_batch_\(index)",
                deadlines: [baseDeadline.addingTimeInterval(Double(index) * 0.0005)] // 0ms, 0.5ms, 1ms
            )
        }

        for handler in handlers {
            coordinator.register(handler)
        }

        try await Task.sleep(for: .milliseconds(15))

        // All should have been processed (within 2ms tolerance)
        for handler in handlers {
            #expect(handler.processCount == 1)
        }

        for handler in handlers {
            coordinator.unregister(handler.dequeueIdentifier)
        }
    }

    @Test("Handler error doesn't crash coordinator")
    func testErrorHandling() async throws {
        let coordinator = VideoDequeueCoordinator.shared

        let now = Ticks.now
        let handler = MockDequeueHandler(
            identifier: "test_error",
            deadlines: [now.addingTimeInterval(0.010)]
        )
        handler.shouldFail = true

        coordinator.register(handler)

        try await Task.sleep(for: .milliseconds(15))

        // Handler should have been called despite error
        #expect(handler.processCount == 1)

        coordinator.unregister(handler.dequeueIdentifier)
    }

    @Test("Unregistered handler is removed")
    func testUnregister() async throws {
        let coordinator = VideoDequeueCoordinator.shared

        let now = Ticks.now
        let handler = MockDequeueHandler(
            identifier: "test_unregister",
            deadlines: [
                now.addingTimeInterval(0.010),
                now.addingTimeInterval(0.020)
            ]
        )

        coordinator.register(handler)
        try await Task.sleep(for: .milliseconds(5))

        coordinator.unregister(handler.dequeueIdentifier)

        try await Task.sleep(for: .milliseconds(20))

        // Should not have been called after unregister
        #expect(handler.processCount == 0)
    }
}
