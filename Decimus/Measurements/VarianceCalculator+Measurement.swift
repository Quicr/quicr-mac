// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension VarianceCalculator {
    final class VarianceCalculatorMeasurement: MeasurementBase {
        init(source: String, stage: String) {
            super.init(name: "VarianceCalculator", tags: ["sourceId": source, "stage": stage])
        }

        func reportVariance(variance: TimeInterval, timestamp: Date, count: Int) {
            let tags: [String: String] = ["count": "\(count)"]
            record(field: "variance", value: variance, timestamp: timestamp, tags: tags)
        }
    }
}
