// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class MockSubmitter: MetricsSubmitter {
    func register(measurement: Measurement) { }
    func unregister(id: UUID) {}
    func submit() { }
}
