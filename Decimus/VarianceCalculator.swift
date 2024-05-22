import Foundation

/// Calculate the variance between a set of timestamped events and their time of occurance.
class VarianceCalculator {
    private var variances: [TimeInterval: [Date]] = [:]
    private let varianceMaxCount: Int
    private let expectedOccurrences: Int
    private let measurement: VarianceCalculatorMeasurement?

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
            self.measurement = measurement
            Task(priority: .utility) {
                await submitter.register(measurement: measurement)
            }
        } else {
            self.measurement = nil
        }
    }

    /// Record a variance.
    func calculateSetVariance(timestamp: TimeInterval, now: Date) -> TimeInterval? {
        // Cleanup.
        if self.variances.count > self.varianceMaxCount {
            for index in 0...self.varianceMaxCount / 2 {
                let variance = self.variances.remove(at: self.variances.index(self.variances.startIndex,
                                                                              offsetBy: index))
                _ = calculateSetVariance(times: variance.value, now: now)
            }
        }

        guard var variances = self.variances[timestamp] else {
            self.variances[timestamp] = [now]
            return nil
        }

        variances.append(now)
        guard variances.count == self.expectedOccurrences else {
            // If we're not done, just store for next time.
            self.variances[timestamp] = variances
            return nil
        }

        // We're done, remove and report.
        self.variances.removeValue(forKey: timestamp)
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
            Task(priority: .utility) {
                await measurement.reportVariance(variance: variance, timestamp: now, count: times.count)
            }
        }
        return variance
    }
}
