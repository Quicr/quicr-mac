// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import AVFAudio
import CoreAudio
import Darwin
import Synchronization
import Testing
import XCTest
@testable import QuicR

struct AudioUtilitiesTests {
    @Test("Test Host/Date Conversion")
    func hostDateConversion() {
        // Capture monotonic time
        let now = Date.now
        let ticks = Ticks.now

        // Convert ticks to date
        let hostDate = ticks.hostDate

        // Ticks to date should be correct.
        #expect(abs(hostDate.timeIntervalSince(now)) < 0.001)
    }

    @Test("Test Ticks TimeInterval Addition")
    func ticksAddition() {
        let start = Ticks.now
        let interval: TimeInterval = 1.5
        let end = start + interval.ticks

        // Check ticks were advanced correctly
        let tickDiff = (end - start).seconds
        #expect(abs(tickDiff - interval) < 0.001, "Ticks should advance by \(interval)s")
    }
}

/// Exercises real engine I/O with injected configuration notifications.
@MainActor
final class TestDecimusAudioEngine: XCTestCase {
    nonisolated override func record(_ issue: XCTIssue) {
        if issue.compactDescription.contains("lower QoS") {
            // Treat priority inversions as failures in this lifecycle suite.
            super.record(XCTIssue(type: .assertionFailure,
                                  compactDescription: issue.compactDescription,
                                  detailedDescription: issue.detailedDescription,
                                  sourceCodeContext: issue.sourceCodeContext,
                                  associatedError: issue.associatedError,
                                  attachments: issue.attachments))
        } else {
            super.record(issue)
        }
    }

    func testEngineDestructionDoesNotBlockMainActor() async throws {
        let disposed = expectation(description: "underlying engine disposed off main")
        var audio: DecimusAudioEngine? = try await DecimusAudioEngine(engine: DisposalObservedEngine {
            XCTAssertFalse(Thread.isMainThread, "Voice-processing engine destruction blocks the main thread")
            XCTAssertEqual(qos_class_self(), QOS_CLASS_DEFAULT)
            disposed.fulfill()
        })
        try await audio?.start()
        try await audio?.stop()
        audio = nil
        await fulfillment(of: [disposed], timeout: 3)
    }

    func testUserInitiatedRepeatedStartStop() async throws {
        let operation = Task(priority: .userInitiated) {
            let audio = try await DecimusAudioEngine()
            for _ in 0..<4 {
                try await audio.start()
                try await audio.stop()
            }
        }
        try await operation.value
    }

    func testConcurrentGraphChangesDuringRestart() async throws {
        let audio = try await DecimusAudioEngine()
        let graphChanges = Task.detached(priority: .high) {
            for index in 0..<20 {
                let node = AVAudioSourceNode { silence, _, _, data in
                    silence.pointee = true
                    for buffer in UnsafeMutableAudioBufferListPointer(data) {
                        if let destination = buffer.mData {
                            memset(destination, 0, Int(buffer.mDataByteSize))
                        }
                    }
                    return noErr
                }
                let identifier = "qos-stress-\(index)"
                try audio.addPlayer(identifier: identifier, node: node)
                try audio.removePlayer(identifier: identifier)
                await Task.yield()
            }
        }
        for _ in 0..<8 {
            try await audio.start()
            try await audio.stop()
        }
        try await graphChanges.value
    }

    func testStopAfterHardwareStopDoesNotRestart() async throws {
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications)
        try await audio.start()
        XCTAssertTrue(engine.isRunning)

        // A device configuration change stops I/O before delivering its notification.
        engine.stop()
        try await audio.stop()
        notifications.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(engine.isRunning, "A delayed configuration notification restarted stopped audio")
        try await audio.stop()
    }

    func testConfigurationChangeBeforeStartDoesNotStart() async throws {
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications)
        notifications.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(engine.isRunning)
        try await audio.stop()
    }

    func testUnrelatedConfigurationChangeIsIgnored() async throws {
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications)
        try await audio.start()
        engine.stop()
        let unrelated = AVAudioEngine()
        notifications.post(name: .AVAudioEngineConfigurationChange, object: unrelated)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(engine.isRunning)
        try await audio.stop()
    }

    func testOwnConfigurationChangeRestartsWantedAudio() async throws {
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications)
        try await audio.start()
        engine.stop()
        notifications.post(name: .AVAudioEngineConfigurationChange, object: engine)
        let deadline = ContinuousClock.now + .seconds(3)
        while !engine.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.isRunning)
        try await audio.stop()
    }

    func testDuplicatePlayerDoesNotAttachAnotherNode() async throws {
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications)
        let first = AVAudioSourceNode { _, _, _, _ in noErr }
        let duplicate = AVAudioSourceNode { _, _, _, _ in noErr }
        try audio.addPlayer(identifier: "source", node: first)
        XCTAssertThrowsError(try audio.addPlayer(identifier: "source", node: duplicate))
        XCTAssertTrue(engine.attachedNodes.contains(first))
        XCTAssertFalse(engine.attachedNodes.contains(duplicate))
        try audio.removePlayer(identifier: "source")
        XCTAssertFalse(engine.attachedNodes.contains(first))
        try await audio.stop()
    }

    func testStopDuringActivationDoesNotStartIO() async throws {
        let activating = expectation(description: "session activation suspended")
        let stopped = expectation(description: "stop intent applied")
        let gate = ActivationGate(entered: activating)
        let engine = retainForTeardown(StopObservedEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications) { active in
            if active { await gate.suspend() }
        }
        engine.onStop = { stopped.fulfill() }
        let start = Task { try await audio.start() }
        await fulfillment(of: [activating], timeout: 3)
        let stop = Task { try await audio.stop() }
        await fulfillment(of: [stopped], timeout: 3)
        await gate.resume()
        do {
            try await start.value
            XCTFail("A stopped start request should be cancelled")
        } catch is CancellationError { }
        try await stop.value
        XCTAssertFalse(engine.isRunning)
        #if !os(macOS)
        try await Task.detached { try AVAudioSession.sharedInstance().setActive(false) }.value
        #endif
    }

    func testCancellationDuringActivationDoesNotStartIO() async throws {
        let activating = expectation(description: "session activation suspended")
        let stopped = expectation(description: "cancelled start stopped I/O")
        let gate = ActivationGate(entered: activating)
        let engine = retainForTeardown(StopObservedEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications) { active in
            if active { await gate.suspend() }
        }
        engine.onStop = { stopped.fulfill() }
        let start = Task { try await audio.start() }
        await fulfillment(of: [activating], timeout: 3)
        start.cancel()
        await fulfillment(of: [stopped], timeout: 3)
        await gate.resume()
        do {
            try await start.value
            XCTFail("A cancelled activation should not start audio")
        } catch is CancellationError { }
        XCTAssertFalse(engine.isRunning)
        engine.onStop = nil
        try await audio.stop()
        #if !os(macOS)
        try await Task.detached { try AVAudioSession.sharedInstance().setActive(false) }.value
        #endif
    }

    func testStartWaitsForPendingDeactivation() async throws {
        let deactivating = expectation(description: "session deactivation suspended")
        let gate = ActivationGate(entered: deactivating)
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications) { active in
            if !active { await gate.suspend() }
        }
        try await audio.start()
        let stop = Task { try await audio.stop() }
        await fulfillment(of: [deactivating], timeout: 3)
        let restart = Task { try await audio.start() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(engine.isRunning, "I/O started before the preceding deactivation completed")
        await gate.resume()
        try await stop.value
        try await restart.value
        XCTAssertTrue(engine.isRunning)
        try await audio.stop()
        #if !os(macOS)
        try await Task.detached { try AVAudioSession.sharedInstance().setActive(false) }.value
        #endif
    }

    #if !os(macOS)
    func testInterruptionBlocksConfigurationRestartUntilResumption() async throws {
        let engine = retainForTeardown(AVAudioEngine())
        let notifications = NotificationCenter()
        let audio = try await DecimusAudioEngine(engine: engine, notifications: notifications)
        try await audio.start()
        let session = AVAudioSession.sharedInstance()
        notifications.post(name: AVAudioSession.interruptionNotification,
                           object: session,
                           userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        notifications.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(engine.isRunning)
        notifications.post(name: AVAudioSession.interruptionNotification,
                           object: session,
                           userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                      AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        let deadline = ContinuousClock.now + .seconds(3)
        while !engine.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(engine.isRunning)
        try await audio.stop()
    }
    #endif

    private func retainForTeardown<Engine: AVAudioEngine>(_ engine: Engine) -> Engine {
        let retained = Mutex<Engine?>(engine)
        addTeardownBlock {
            await Task.detached(priority: .medium) {
                retained.withLock { $0 = nil }
            }.value
        }
        return engine
    }

    private actor ActivationGate {
        private let entered: XCTestExpectation
        private var pending: CheckedContinuation<Void, Never>?
        private var released = false

        init(entered: XCTestExpectation) {
            self.entered = entered
        }

        func suspend() async {
            guard !released else { return }
            await withCheckedContinuation {
                self.pending = $0
                self.entered.fulfill()
            }
        }

        func resume() {
            self.released = true
            self.pending?.resume()
            self.pending = nil
        }
    }

    private final class DisposalObservedEngine: AVAudioEngine, @unchecked Sendable {
        private let onDispose: @Sendable () -> Void

        init(onDispose: @escaping @Sendable () -> Void) {
            self.onDispose = onDispose
            super.init()
        }

        deinit { onDispose() }
    }

    private final class StopObservedEngine: AVAudioEngine, @unchecked Sendable {
        var onStop: (() -> Void)?

        override func stop() {
            super.stop()
            onStop?()
        }
    }
}
