// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

struct AudioUtilitiesTests {
    @Test("Test Host/Date Conversion")
    func hostDateConversion() {
        let host = Ticks(mach_absolute_time())
        let hostDate = host.hostDate
        let backToHost = hostDate.timeIntervalSince1970.ticks
        let tickTolerance = 50
        let diff = Int128(backToHost) - Int128(host)
        #expect(diff <= tickTolerance, "Host time should match after conversion")
    }
}
