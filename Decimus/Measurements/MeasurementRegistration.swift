// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class MeasurementRegistration<Metric> where Metric: Measurement {
    let measurement: Metric
    private let submitter: MetricsSubmitter

    init(measurement: Metric, submitter: MetricsSubmitter) {
        self.measurement = measurement
        self.submitter = submitter
        submitter.register(measurement: measurement)
    }

    deinit {
        self.submitter.unregister(id: self.measurement.id)
    }
}
