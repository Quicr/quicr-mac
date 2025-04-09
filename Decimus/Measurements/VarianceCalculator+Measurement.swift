// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension VarianceCalculator {
    class VarianceCalculatorMeasurement: Measurement {
        init(source: String, stage: String) {
            var tags: [String: String] = [:]
            tags["sourceId"] = source
            tags["stage"] = stage
            super.init(name: "VarianceCalculator", tags: tags)
        }

        func reportVariance(variance: TimeInterval, timestamp: Date, count: Int) {
            let tags: [String: String] = ["count": "\(count)"]
            record(field: "variance", value: variance, timestamp: timestamp, tags: tags)
        }
    }
}
