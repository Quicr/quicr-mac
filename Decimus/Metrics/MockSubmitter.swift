// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

final class MockSubmitter: MetricsSubmitter {
    func register(measurement: Measurement) { }
    func submit() { }
}
