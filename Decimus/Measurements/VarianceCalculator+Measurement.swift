// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

extension VarianceCalculator {
    actor VarianceCalculatorMeasurement: Measurement {
        let id = UUID()
        var name: String = "VarianceCalculator"
        var fields: Fields = [:]
        var tags: [String: String] = [:]

        init(source: String, stage: String) {
            tags["sourceId"] = source
            tags["stage"] = stage
        }

        func reportVariance(variance: TimeInterval, timestamp: Date, count: Int) {
            let tags: [String: String] = ["count": "\(count)"]
            record(field: "variance", value: variance, timestamp: timestamp, tags: tags)
        }
    }
}
