import Foundation
import Synchronization
/// Multi-stream Wi-Fi scan spike detection based on arrival intervals.
class WiFiScanDetector {
    private var streamData: [String: Stream] = [:]
    private var detectedSpikes: [Date] = []
    private var intervals: [TimeInterval] = []
    private var spikeMagnitudes: [TimeInterval] = [] // Track spike sizes
    private let spikeThreshold: TimeInterval = 0.080 // 80ms
    private let historyLimit = 100
    private let baselineWindow = 5
    private let logger = DecimusLogger(WiFiScanDetector.self)
    private let spikeDuration: TimeInterval = 5
    private let seedInterval: TimeInterval
    private let measurement: MeasurementRegistration<WiFiScanDetectorMeasurement>?
    private var metricsTask: Task<Void, Never>?
    private let defaultSpikeInterval: TimeInterval = 0.2
    private let maxSpikeThreshold: TimeInterval = 2.0
    typealias Callback = () -> Void
    private let callbacks: Mutex<[Int: Callback]> = .init([:])
    private var currentToken: Int = 0
    private let spikeId = Atomic<Int>(0)
    private var inSeedSpike = false

    private class Stream {
        var intervalHistory: [(timestamp: Date, interval: TimeInterval)] = []
        var baselineInterval: TimeInterval = 0.020 // 20ms default
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
                    if let time = prediction.timeToScan {
                        await self.measurement?.measurement.prediction(timeUntil: time, timestamp: now)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } else {
            self.measurement = nil
            self.metricsTask = nil
        }
    }

    func registerNotifyCallback(_ callback: @escaping Callback) -> Int {
        let currentToken = self.currentToken
        self.currentToken += 1
        self.callbacks.withLock { $0[currentToken] = callback }
        return currentToken
    }

    func removeNotifyCallback(token: Int) {
        self.callbacks.withLock { _ = $0.removeValue(forKey: token) }
    }

    /// Add a new packet interval measurement from a specific stream
    func addIntervalMeasurement(interval: TimeInterval, namespace: String, timestamp: Date) {
        // Initialize stream if needed
        let stream: Stream
        if let existingStream = self.streamData[namespace] {
            stream = existingStream
        } else {
            stream = Stream(namespace: namespace)
            self.streamData[namespace] = stream
        }

        stream.intervalHistory.append((timestamp: timestamp, interval: interval))

        // Keep history bounded per stream
        if stream.intervalHistory.count > self.historyLimit {
            stream.intervalHistory.removeFirst()
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
        var maxSpikeSize: TimeInterval = 0
        let timeWindow: TimeInterval = 1.0 // 1 second window

        for stream in self.streamData.values {
            // Get recent measurements within time window
            let recentMeasurements = stream.intervalHistory.filter {
                abs($0.timestamp.timeIntervalSince(timestamp)) < timeWindow
            }

            guard !recentMeasurements.isEmpty else { continue }
            totalStreams += 1

            // Check if this stream has elevated intervals and track max size
            if let spikeSize = self.getStreamSpikeSize(stream: stream, recentMeasurements: recentMeasurements) {
                streamsWithSpikes += 1
                maxSpikeSize = max(maxSpikeSize, spikeSize)
            }
        }

        // Store the spike magnitude for prediction
        guard streamsWithSpikes >= Int(ceil(Double(totalStreams) / 2.0)) else {
            return false
        }

        // This was a spike.
        self.spikeMagnitudes.append(maxSpikeSize)
        if self.spikeMagnitudes.count > 20 { // Keep bounded
            self.spikeMagnitudes.removeFirst()
        }
        return true
    }

    /// Check if a specific stream has a spike and return the spike size
    private func getStreamSpikeSize(stream: Stream,
                                    recentMeasurements: [(timestamp: Date, interval: TimeInterval)]) -> TimeInterval? {
        let maxInterval = recentMeasurements.map(\.interval).max() ?? 0

        // Early detection: use absolute threshold if insufficient history
        if stream.intervalHistory.count < self.baselineWindow {
            let earlyThreshold = self.spikeThreshold * 2.0
            return maxInterval > earlyThreshold ? maxInterval : nil
        }

        // Calculate baseline for this stream
        let baseline = stream.intervalHistory.suffix(self.baselineWindow)
            .map(\.interval)
            .reduce(0, +) / Double(self.baselineWindow)

        // Update baseline for this stream
        stream.baselineInterval = baseline

        // It's a spike if it's above threshold and significantly above baseline
        let isSpike = maxInterval > self.spikeThreshold && maxInterval > (baseline * 2.5)
        return isSpike ? maxInterval : nil
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
        for callback in self.callbacks.get() {
            callback.value()
        }
        self.spikeId.add(1, ordering: .acquiringAndReleasing)

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

    /// Predict next Wi-Fi scan timing and expected length.
    /// - Returns: (timeToScan, predictedLength).
    func predictNextScan(from: Date) -> (timeToScan: TimeInterval?, predictedLength: TimeInterval, spikeId: Int) {
        var thisSpikeId = self.spikeId.load(ordering: .acquiring)
        guard let lastSpike = self.detectedSpikes.last else {
            return (nil, self.defaultSpikeInterval, thisSpikeId)
        }

        let timeSinceLastSpike = from.timeIntervalSince(lastSpike)

        // Predict length of spike.
        let intervals = self.spikeMagnitudes.filter { $0 <= self.maxSpikeThreshold }
        let predictedLength = intervals.isEmpty ? self.defaultSpikeInterval : intervals.reduce(0) { max($0, $1) }

        // Use seeded interval if we don't have enough real data
        if self.intervals.count < 3 {
            let timeToNextScan = max(0, self.seedInterval - timeSinceLastSpike)
            var spikeId = thisSpikeId
            if timeToNextScan < 0.0,
               !self.inSeedSpike {
                self.inSeedSpike = true
                spikeId = self.spikeId.add(1, ordering: .acquiringAndReleasing).newValue
            } else if timeToNextScan >= 0.0 && self.inSeedSpike {
                self.inSeedSpike = false
            }
            return (timeToNextScan, predictedLength, spikeId)
        }

        // Use measured intervals
        let avgInterval = self.intervals.reduce(0, +) / Double(self.intervals.count)
        let timeToNextScan = max(0, avgInterval - timeSinceLastSpike)
        return (timeToNextScan, predictedLength, thisSpikeId)
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
