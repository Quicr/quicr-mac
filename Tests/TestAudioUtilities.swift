// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
@testable import QuicR

struct AudioUtilitiesTests {
    @Test("Test Host/Date Conversion")
    func hostDateConversion() {
        let host = mach_absolute_time()
        let hostDate = hostToDate(host)
        let backToHost = dateToHost(hostDate)
        let tickTolerance = 1
        let diff = Int128(backToHost) - Int128(host)
        #expect(diff <= tickTolerance, "Host time should match after conversion")
    }
}
