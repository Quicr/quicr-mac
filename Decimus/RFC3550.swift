// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Calculates interarrival jitter according to RFC 3550.
final class RFC3550Jitter: Sendable {
    private nonisolated(unsafe) var transit: TimeInterval?
    /// Current jitter value.
    private(set) nonisolated(unsafe) var jitter: TimeInterval = 0
    /// Exponentially smoothed value.
    private(set) nonisolated(unsafe) var smoothed: TimeInterval = 0
    private let measurement: RFC3550JitterMeasurement?

    /// Alpha for exponential smoothing.
    private let alpha = 0.1

    init(identifier: String, submitter: MetricsSubmitter?) {
        guard let submitter else {
            self.measurement = nil
            return
        }
        let measurement = RFC3550JitterMeasurement(namespace: identifier)
        submitter.register(measurement: measurement)
        self.measurement = measurement
    }

    /// Record an arrival timestamp. This must only be called from 1 concurrency context.
    func record(timestamp: TimeInterval, arrival: Date) {
        // Calculation.
        let transit = arrival.timeIntervalSince1970 - timestamp
        guard let lastTransit = self.transit else {
            self.transit = transit
            return
        }

        var d = transit - lastTransit
        self.transit = transit
        if d < 0 {
            d = -d
        }
        self.jitter += (1.0 / 16.0) * (d - self.jitter)

        // Smoothed.
        self.smoothed = self.alpha * self.jitter + (1 - self.alpha) * self.smoothed

        // Record metric.
        self.measurement?.jitter(jitter: self.jitter, smoothed: self.smoothed, date: arrival)
    }
}

final class RFC3550JitterMeasurement: MetricsMeasurement {
    let storage = MeasurementStorage()
    let name = "RFC3550"
    let tags: [String: String]

    init(namespace: QuicrNamespace) {
        self.tags = ["namespace": namespace]
    }

    func jitter(jitter: TimeInterval, smoothed: TimeInterval, date: Date) {
        self.record(field: "jitter", value: jitter, timestamp: date)
        self.record(field: "smoothed", value: smoothed, timestamp: date)
    }
}
