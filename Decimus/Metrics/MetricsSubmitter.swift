// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

protocol MetricsSubmitter: Actor {
    func register(measurement: Measurement)
    func unregister(id: UUID)
    func submit() async
}
