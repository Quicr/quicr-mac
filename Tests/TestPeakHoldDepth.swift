// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Testing
import Numerics
@testable import QuicR

struct TestPeakHoldDepth {
    private func makeDepth() -> PeakHoldDepth {
        .init(initial: 0.2, hold: 10, floor: 0.03, ceiling: 0.5, margin: 0.01, decayRate: 0.02)
    }

    private func arrival(_ seconds: TimeInterval) -> Ticks {
        (1000 + seconds).ticks
    }

    @Test("Starts from the initial target and decays to the floor")
    func decaysToFloor() {
        var depth = self.makeDepth()
        #expect(depth.update(lateness: 0, arrival: self.arrival(0.5)) == 0.2)
        let decayed = depth.update(lateness: 0, arrival: self.arrival(1.5))
        #expect(decayed.isApproximatelyEqual(to: 0.18, absoluteTolerance: 1e-6))
        var target = decayed
        for second in stride(from: 2.5, through: 20.5, by: 1) {
            target = depth.update(lateness: 0, arrival: self.arrival(second))
        }
        #expect(target == 0.03)
    }

    @Test("Raises immediately and holds the peak for the hold window")
    func holdsPeak() {
        var depth = self.makeDepth()
        let raised = depth.update(lateness: 0.3, arrival: self.arrival(0.5))
        #expect(raised.isApproximatelyEqual(to: 0.31, absoluteTolerance: 1e-9))
        for second in stride(from: 1.5, through: 9.5, by: 1) {
            #expect(depth.update(lateness: 0, arrival: self.arrival(second)) == raised)
        }
        let released = depth.update(lateness: 0, arrival: self.arrival(10.5))
        #expect(released.isApproximatelyEqual(to: raised - 0.02, absoluteTolerance: 1e-6))
    }

    @Test("Clamps to the ceiling")
    func clampsToCeiling() {
        var depth = self.makeDepth()
        #expect(depth.update(lateness: 2, arrival: self.arrival(0.5)) == 0.5)
    }

    @Test("The opt-in defaults to disabled and persists")
    func configurationPersistence() throws {
        var config = JitterBuffer.Config()
        config.minDepth = 0.1
        let disabled = try JSONDecoder().decode(JitterBuffer.Config.self, from: JSONEncoder().encode(config))
        #expect(!disabled.peakHold)
        #expect(disabled.minDepth == 0.1)

        config.peakHold = true
        let enabled = try JSONDecoder().decode(JitterBuffer.Config.self, from: JSONEncoder().encode(config))
        #expect(enabled.peakHold)
    }
}

struct TestSharedPeakHoldDepth {
    private let frame: TimeInterval = 1.0 / 30

    private func makeDepth() -> SharedPeakHoldDepth {
        .init(initial: 0.03, allowance: 0.1)
    }

    private func arrival(_ seconds: TimeInterval) -> Ticks {
        (1000 + seconds).ticks
    }

    @Test("Every layer receives the target needed by the latest layer")
    func layersShareTarget() {
        let depth = self.makeDepth()
        _ = depth.update(timestamp: 0, lateness: 0.05, arrival: self.arrival(0.05))
        let raised = depth.update(timestamp: 0, lateness: 0.12, arrival: self.arrival(0.12))
        #expect(raised.isApproximatelyEqual(to: 0.13, absoluteTolerance: 1e-9))
        let sibling = depth.update(timestamp: self.frame, lateness: 0.05, arrival: self.arrival(self.frame + 0.05))
        #expect(sibling == raised)
    }

    @Test("Later layers extend the target by no more than the allowance")
    func allowanceLimitsLaterLayers() {
        let depth = self.makeDepth()
        _ = depth.update(timestamp: 0, lateness: 0.05, arrival: self.arrival(0.05))
        let late = depth.update(timestamp: 0, lateness: 0.4, arrival: self.arrival(0.4))
        #expect(late.isApproximatelyEqual(to: 0.16, absoluteTolerance: 1e-9))
    }

    @Test("Objects from a lagging layer do not count as first arrivals")
    func laggingLayerIsNotFirst() {
        let depth = self.makeDepth()
        _ = depth.update(timestamp: 0, lateness: 0.05, arrival: self.arrival(0.05))
        _ = depth.update(timestamp: self.frame, lateness: 0.05, arrival: self.arrival(self.frame + 0.05))
        let lagging = depth.update(timestamp: 0, lateness: 0.35, arrival: self.arrival(0.35))
        #expect(lagging.isApproximatelyEqual(to: 0.16, absoluteTolerance: 1e-9))
    }

    @Test("A stall on every layer raises the target fully")
    func stallOnAllLayers() {
        let depth = self.makeDepth()
        _ = depth.update(timestamp: 0, lateness: 0.05, arrival: self.arrival(0.05))
        let stalled = depth.update(timestamp: self.frame, lateness: 0.3, arrival: self.arrival(self.frame + 0.3))
        #expect(stalled.isApproximatelyEqual(to: 0.31, absoluteTolerance: 1e-9))
        let sibling = depth.update(timestamp: self.frame, lateness: 0.32, arrival: self.arrival(self.frame + 0.32))
        #expect(sibling.isApproximatelyEqual(to: 0.33, absoluteTolerance: 1e-9))
    }
}
