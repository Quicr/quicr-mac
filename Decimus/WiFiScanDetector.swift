import Foundation

/// Multi-stream Wi-Fi scan spike detection based on arrival intervals.
class WiFiScanDetector {
    private var streamData: [String: Stream] = [:]
    private var detectedSpikes: [Date] = []
    private var intervals: [TimeInterval] = []
    private let spikeThreshold: TimeInterval = 0.080 // 80ms
    private let historyLimit = 100
    private let baselineWindow = 5
    private let logger = DecimusLogger(WiFiScanDetector.self)
    private let spikeDuration: TimeInterval = 5
    private let seedInterval: TimeInterval
    private let measurement: MeasurementRegistration<WiFiScanDetectorMeasurement>?
    private var metricsTask: Task<Void, Never>?

    private class Stream {
        var jitterHistory: [(timestamp: Date, jitter: TimeInterval)] = []
        var baselineJitter: TimeInterval = 0.020 // 20ms default
        let namespace: String
        init(namespace: String) {
            self.namespace = namespace
        }
    }

    init(expectedInterval: TimeInterval, submitter: MetricsSubmitter?) {
        self.seedInterval = expectedInterval
        if let subitter = submitter {
            self.measurement = .init(measurement: WiFiScanDetectorMeasurement(),
                                     submitter: subitter)
            self.metricsTask = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    guard let self = self else { return }
                    let now = Date.now
                    let prediction = self.predictNextScan(from: now)
                    print("Predicting: \(prediction)")
                    await self.measurement?.measurement.prediction(timeUntil: prediction, timestamp: now)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            self.measurement = nil
            self.metricsTask = nil
        }
    }

    /// Add a new jitter measurement from a specific stream
    func addJitterMeasurement(jitter: TimeInterval, namespace: String, timestamp: Date) {
        // Initialize stream if needed
        let stream: Stream
        if let existingStream = self.streamData[namespace] {
            stream = existingStream
        } else {
            stream = Stream(namespace: namespace)
            self.streamData[namespace] = stream
        }

        stream.jitterHistory.append((timestamp: timestamp, jitter: jitter))

        // Keep history bounded per stream
        if stream.jitterHistory.count > self.historyLimit {
            stream.jitterHistory.removeFirst()
        }

        // Check for spike across all streams
        if self.isGlobalSpike(at: timestamp) {
            self.recordSpike(at: timestamp)
        }
    }

    /// Check for Wi-Fi scan spike across all streams at given timestamp
    private func isGlobalSpike(at timestamp: Date) -> Bool {
        var streamsWithSpikes = 0
        var totalStreams = 0
        let timeWindow: TimeInterval = 1.0 // 1 second window
        for stream in self.streamData.values {
            // Get recent measurements within time window
            let recentMeasurements = stream.jitterHistory.filter {
                abs($0.timestamp.timeIntervalSince(timestamp)) < timeWindow
            }

            guard !recentMeasurements.isEmpty else { continue }
            totalStreams += 1

            // Check if this stream has elevated jitter
            if self.hasStreamSpike(stream: stream, recentMeasurements: recentMeasurements) {
                streamsWithSpikes += 1
            }
        }

        // Are all streams showing spikes?
        let threshold = ceil(Double(totalStreams) / 2.0)
        return streamsWithSpikes >= Int(threshold)
    }

    /// Check if a specific stream has a spike
    private func hasStreamSpike(stream: Stream, recentMeasurements: [(timestamp: Date, jitter: TimeInterval)]) -> Bool {
        let maxJitter = recentMeasurements.map(\.jitter).max() ?? 0

        // Early detection: use absolute threshold if insufficient history
        if stream.jitterHistory.count < self.baselineWindow {
            let earlyThreshold = self.spikeThreshold * 2.0
            return maxJitter > earlyThreshold
        }

        // Calculate baseline for this stream
        let baseline = stream.jitterHistory.suffix(self.baselineWindow)
            .map(\.jitter)
            .reduce(0, +) / Double(self.baselineWindow)

        // It's a spike if it's above threshold and baseline.
        return maxJitter > self.spikeThreshold && maxJitter > (baseline * 2.5)
    }

    /// Record a detected spike and calculate interval
    private func recordSpike(at timestamp: Date) {
        // Avoid duplicate spikes within an event.
        if let lastSpike = self.detectedSpikes.last,
           timestamp.timeIntervalSince(lastSpike) < self.spikeDuration {
            return
        }

        self.detectedSpikes.append(timestamp)
        self.logger.warning("📡 Wi-Fi spike!")

        // Calculate interval if we have previous spike
        if self.detectedSpikes.count >= 2 {
            let interval = timestamp.timeIntervalSince(self.detectedSpikes[self.detectedSpikes.count - 2])
            self.intervals.append(interval)
            // Keep intervals bounded
            if self.intervals.count > self.baselineWindow {
                self.intervals.removeFirst()
            }
        }

        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.recordSpike(timestamp: timestamp)
            }
        }
    }

    /// Predict.
    /// - Returns: Time to next scan.
    func predictNextScan(from: Date) -> TimeInterval {
        guard let lastSpike = self.detectedSpikes.last else {
            return 0
        }

        let timeSinceLastSpike = from.timeIntervalSince(lastSpike)

        // Use seeded interval if we don't have enough real data
        if self.intervals.count < 3 {
            let timeToNextScan = max(0, self.seedInterval - timeSinceLastSpike)
            return timeToNextScan
        }

        // Use measured intervals
        let avgInterval = self.intervals.reduce(0, +) / Double(self.intervals.count)
        return max(0, avgInterval - timeSinceLastSpike)
    }
}

actor WiFiScanDetectorMeasurement: Measurement {
    let id = UUID()
    var name: String = "WiFi"
    var fields: Fields = [:]
    var tags: [String: String] = [:]

    func recordSpike(timestamp: Date) {
        self.record(field: "spike", value: 1, timestamp: timestamp)
    }

    func prediction(timeUntil: TimeInterval, timestamp: Date) {
        self.record(field: "prediction", value: timeUntil, timestamp: timestamp)
    }
}
