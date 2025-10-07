// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
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
