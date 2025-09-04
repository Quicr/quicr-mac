// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Calculates interarrival jitter according to RFC 3550.
class RFC3550Jitter {
    private var transit: TimeInterval = 0
    /// Current jitter value.
    private(set) var jitter: TimeInterval = 0
    /// Exponentially smoothed value.
    private(set) var smoothed: TimeInterval = 0
    private let measurement: MeasurementRegistration<RFC3550JitterMeasurement>?

    /// Alpha for exponential smoothing.
    private let alpha = 0.1

    init(identifier: String, submitter: MetricsSubmitter?) {
        guard let submitter else {
            self.measurement = nil
            return
        }
        self.measurement = .init(measurement: .init(namespace: identifier),
                                                    submitter: submitter)
    }

    func record(timestamp: Date, arrival: Date) {
        // Calculation.
        let transit = arrival.timeIntervalSince1970 - timestamp.timeIntervalSince1970
        var d = transit - self.transit // swiftlint:disable:this identifier_name
        self.transit = transit
        if d < 0 {
            d = -d
        }
        self.jitter += (1.0 / 16.0) * (d - self.jitter)

        // Smoothed.
        self.smoothed = self.alpha * self.jitter + (1 - self.alpha) * self.smoothed

        // Record metric.
        if let measurement = self.measurement?.measurement {
            let jitter = self.jitter
            let smoothed = self.smoothed
            Task(priority: .utility) {
                await measurement.jitter(jitter: jitter, smoothed: smoothed, date: arrival)
            }
        }
    }
}

actor RFC3550JitterMeasurement: Measurement {
    let id = UUID()
    var name = "RFC3550"
    var fields = Fields()
    var tags: [String: String] = [:]

    init(namespace: QuicrNamespace) {
        self.tags["namespace"] = namespace
    }

    func jitter(jitter: TimeInterval, smoothed: TimeInterval, date: Date) {
        self.record(field: "jitter", value: jitter, timestamp: date)
        self.record(field: "smoothed", value: smoothed, timestamp: date)
    }
}
