// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

protocol MetricsSubmitter: AnyObject, Sendable {
    func register(measurement: MetricsMeasurement)
    func submit() async
}
