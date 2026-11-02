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

    @Test("Saved configurations without the opt-in decode with it disabled, and the opt-in persists")
    func configurationPersistence() throws {
        var config = JitterBuffer.Config()
        config.minDepth = 0.1
        let existing = try JSONDecoder().decode(JitterBuffer.Config.self, from: JSONEncoder().encode(config))
        #expect(!existing.peakHold)
        #expect(existing.minDepth == 0.1)

        config.peakHold = true
        let enabled = try JSONDecoder().decode(JitterBuffer.Config.self, from: JSONEncoder().encode(config))
        #expect(enabled.peakHold)
    }
}
