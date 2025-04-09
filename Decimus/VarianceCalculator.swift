// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

/// Calculate the variance between a set of timestamped events and their time of occurance.
class VarianceCalculator {
    private let variances: Mutex<[TimeInterval: [Date]]> = .init([:])
    private let varianceMaxCount: Int
    private let expectedOccurrences: Int
    private let measurement: MeasurementRegistration<VarianceCalculatorMeasurement>?

    /// Create a new calculator.
    /// - Parameter expectedOccurences The number of occurences after which a calculation will be completed.
    /// - Parameter max The number of calculations in flight before flushing.
    init(expectedOccurrences: Int,
         max: Int = 10,
         submitter: MetricsSubmitter? = nil,
         source: String? = nil,
         stage: String? = nil) throws {
        self.expectedOccurrences = expectedOccurrences
        self.varianceMaxCount = max
        if let submitter = submitter {
            guard let source = source,
                  let stage = stage else {
                throw "Source & stage needed for metrics"
            }
            let measurement = VarianceCalculatorMeasurement(source: source, stage: stage)
            self.measurement = .init(measurement: measurement, submitter: submitter)
        } else {
            self.measurement = nil
        }
    }

    /// Record a variance.
    func calculateSetVariance(timestamp: TimeInterval, now: Date) -> TimeInterval? {
        let variances = self.variances.withLock { varianceMap in
            // Cleanup.
            if varianceMap.count > self.varianceMaxCount {
                for index in 0...self.varianceMaxCount / 2 {
                    let variance = varianceMap.remove(at: varianceMap.index(varianceMap.startIndex,
                                                                            offsetBy: index))
                    _ = calculateSetVariance(times: variance.value, now: now)
                }
            }

            guard var variances = varianceMap[timestamp] else {
                varianceMap[timestamp] = [now]
                return [Date]?.none
            }

            variances.append(now)
            guard variances.count == self.expectedOccurrences else {
                // If we're not done, just store for next time.
                varianceMap[timestamp] = variances
                return [Date]?.none
            }

            // We're done, remove and report.
            varianceMap.removeValue(forKey: timestamp)
            return variances
        }
        guard let variances = variances else { return nil }
        return calculateSetVariance(times: variances, now: now)
    }

    private func calculateSetVariance(times: [Date], now: Date) -> TimeInterval {
        var oldest = Date.distantFuture
        var newest = Date.distantPast
        for date in times {
            oldest = min(oldest, date)
            newest = max(newest, date)
        }
        let variance = newest.timeIntervalSince(oldest)
        if let measurement = self.measurement {
            measurement.measurement.reportVariance(variance: variance, timestamp: now, count: times.count)
        }
        return variance
    }
}
