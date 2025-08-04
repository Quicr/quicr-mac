import Foundation
import Synchronization
/// Multi-stream Wi-Fi scan spike detection based on arrival intervals.
class WiFiScanDetector {

    // State of streams.
    private var streamData: [String: Stream] = [:]

    // Timestamps of detected spike events.
    private var detectedSpikes: [Date] = []

    // List of intervals between all detected spikes.
    private var intervals: [TimeInterval] = []

    // List of detected spike magnitudes.
    private var spikeMagnitudes: [TimeInterval] = []

    // Constants for magnitudes.
    private let thresholdSpikeMagnitude: TimeInterval = 0.08
    private let defaultSpikeMagnitude: TimeInterval = 0.2
    private let maxSpikeMagnitude: TimeInterval = 2
    private let baselineMultiplier: Double = 2.5

    // Constants for intervals.
    private let spikeDuration: TimeInterval = 5
    private let seedInterval: TimeInterval = 30

    // Constants for length.
    private let defaultSpikeLength: TimeInterval = 5

    // Bounds.
    private let historyLimit = 100
    private let baselineWindow = 5

    // Metrics.
    private let measurement: MeasurementRegistration<WiFiScanDetectorMeasurement>?
    private var metricsTask: Task<Void, Never>?

    // Notifications.
    typealias Callback = () -> Void
    private let callbacks: Mutex<[Int: Callback]> = .init([:])
    private var currentToken: Int = 0
    private let spikeId = Atomic<Int>(0)
    private var inSeedSpike = false

    private let logger = DecimusLogger(WiFiScanDetector.self)

    private class Stream {
        var intervalHistory: [(timestamp: Date, interval: TimeInterval)] = []
        var baselineMagnitude: TimeInterval = 0.02 // 20ms default
        let namespace: String
        init(namespace: String) {
            self.namespace = namespace
        }
    }

    /// Create a Wi-Fi scan detector.
    /// - Parameter submitter: Optional metrics submitter for reporting.
    init(submitter: MetricsSubmitter?) {
        self.intervals.append(self.seedInterval)
        
        guard let submitter = submitter else {
            self.measurement = nil
            self.metricsTask = nil
            return
        }
        self.measurement = .init(measurement: WiFiScanDetectorMeasurement(),
                                 submitter: submitter)
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
    }

    /// Register to be notified of scan events.
    /// - Parameter callback: The callback to invoke when a spike is detected.
    /// - Returns: A token that can be used to remove the callback later.
    func registerNotifyCallback(_ callback: @escaping Callback) -> Int {
        let currentToken = self.currentToken
        self.currentToken += 1
        self.callbacks.withLock { $0[currentToken] = callback }
        return currentToken
    }

    /// Remove a previously registered notification callback.
    /// - Parameter token: The token given on registration.
    func removeNotifyCallback(token: Int) {
        self.callbacks.withLock { _ = $0.removeValue(forKey: token) }
    }

    /// Add a new object interval measurement from a specific stream
    /// - Parameter interval: The object interval between packets in seconds.
    /// - Parameter namespace: The namespace of the stream.
    /// - Parameter timestamp: The timestamp of the measurement.
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

    /// Was there a global spike at the given timestamp?
    /// - Parameter timestamp: The timestamp to check.
    /// - Returns: True if a global spike was detected.
    private func isGlobalSpike(at timestamp: Date) -> Bool {
        var streamsWithSpikes = 0
        var totalStreams = 0
        var maxSpikeSize: TimeInterval = 0
        let timeWindow: TimeInterval = 1.0 // 1 second window

        for stream in self.streamData.values {
            // Recent measurements only.
            stream.intervalHistory = stream.intervalHistory
                .filter { $0.timestamp.timeIntervalSince(timestamp) >= -timeWindow }

            guard !stream.intervalHistory.isEmpty else { continue }
            totalStreams += 1

            // Check if this stream has elevated intervals and track max size
            if let spikeSize = self.getStreamSpikeSize(stream: stream) {
                streamsWithSpikes += 1
                maxSpikeSize = max(maxSpikeSize, spikeSize)
            }
        }

        // Store the spike magnitude for prediction
        assert(streamsWithSpikes <= totalStreams)
        guard streamsWithSpikes == totalStreams else { return false }

        // This was a spike.
        self.spikeMagnitudes.append(maxSpikeSize)
        if self.spikeMagnitudes.count > 20 {
            self.spikeMagnitudes.removeFirst()
        }
        return true
    }

    /// Check if a specific stream has a spike and return the spike size.
    /// - Parameter stream: The stream to check.
    /// - Returns: The spike size if a spike was detected, otherwise nil.
    private func getStreamSpikeSize(stream: Stream) -> TimeInterval? {
        let maxInterval = stream.intervalHistory.map(\.interval).max() ?? 0

        // Early detection: use absolute threshold if insufficient history
        if stream.intervalHistory.count < self.baselineWindow {
            let earlyThreshold = self.defaultSpikeMagnitude * self.baselineMultiplier
            return maxInterval > earlyThreshold ? maxInterval : nil
        }

        // Calculate baseline for this stream.
        let baseline = stream.intervalHistory.suffix(self.baselineWindow)
            .map(\.interval)
            .reduce(0, +) / Double(self.baselineWindow)

        // Update baseline for this stream
        stream.baselineMagnitude = baseline

        // It's a spike if it's above threshold and significantly above baseline
        let isSpike = maxInterval > self.defaultSpikeMagnitude && maxInterval > (baseline * self.baselineMultiplier)
        return isSpike ? maxInterval : nil
    }

    /// Record a detected spike and calculate interval
    /// - Parameter timestamp: The timestamp of the spike.
    private func recordSpike(at timestamp: Date) {
        // Avoid duplicate spikes within an event.
        if let lastSpike = self.detectedSpikes.last,
           timestamp.timeIntervalSince(lastSpike) < self.spikeDuration {
            return
        }

        // Record and notify.
        self.logger.warning("📡 Wi-Fi spike!")
        self.detectedSpikes.append(timestamp)
        for callback in self.callbacks.get() {
            callback.value()
        }
        self.spikeId.add(1, ordering: .acquiringAndReleasing)

        // Calculate interval if we have previous spike
        if let lastSpike = self.detectedSpikes.last {
            let interval = timestamp.timeIntervalSince(lastSpike)
            self.logger.info("Time since last spike: \(interval)")
            self.intervals.append(interval)
            if self.intervals.count > self.baselineWindow {
                self.intervals.removeFirst()
            }
        }

        // Metrics.
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.recordSpike(timestamp: timestamp)
            }
        }
    }

    /// Prediction result.
    struct Prediction {
        /// Time until next scan.
        let timeToScan: TimeInterval?
        /// Predicted max inter-object interval during the spike.
        let predictedMagnitude: TimeInterval
        /// Predicted length of the spike event.
        let predictedLength: TimeInterval
        /// ID of the spike for tracking.
        let spikeId: Int
    }

    /// Predict next Wi-Fi scan timing and expected length.
    /// - Returns: Guess of prediction.
    func predictNextScan(from: Date) -> Prediction {
        let thisSpikeId = self.spikeId.load(ordering: .acquiring)
        guard let lastSpike = self.detectedSpikes.last else {
            // No spikes detected yet, use default values.
            return .init(timeToScan: nil,
                         predictedMagnitude: self.defaultSpikeMagnitude,
                         predictedLength: self.defaultSpikeLength,
                         spikeId: thisSpikeId)
        }

        // How long has it been since the last spike?
        let timeSinceLastSpike = from.timeIntervalSince(lastSpike)
        
        // When do we think the next spike will be?
        let estimatedSpikeInterval = self.intervals.reduce(0, +) / Double(self.intervals.count)
        let timeToNextSpike = max(0, estimatedSpikeInterval - timeSinceLastSpike)
        
        // What do we think the max magnitude will be.
        let estimatedSpikeMagnitude = self.spikeMagnitudes.filter { $0 <= self.maxSpikeMagnitude }
        let predictedMagnitude = estimatedSpikeMagnitude.isEmpty ? self.defaultSpikeMagnitude : estimatedSpikeMagnitude.reduce(0) { max($0, $1) }
        
        // How long do we think the next spike will last?
        let estimatedSpikeLength = self.defaultSpikeLength
        

//        // Predict length of the upcoming spike by taking the largest of the recent intervals.
//        let intervals = self.spikeMagnitudes.filter { $0 <= self.maxSpikeThreshold }
//        let predictedLength = intervals.isEmpty ? self.defaultSpikeInterval : intervals.reduce(0) { max($0, $1) }
//
//        // Use seeded interval if we don't have enough real data
//        if self.intervals.count < 3 {
//            let timeToNextScan = max(0, self.seedInterval - timeSinceLastSpike)
//            var spikeId = thisSpikeId
//            if timeToNextScan < 0.0,
//               !self.inSeedSpike {
//                self.inSeedSpike = true
//                spikeId = self.spikeId.add(1, ordering: .acquiringAndReleasing).newValue
//            } else if timeToNextScan >= 0.0 && self.inSeedSpike {
//                self.inSeedSpike = false
//            }
//            return (timeToNextScan, predictedLength, spikeId)
//        }

        return .init(timeToScan: timeToNextSpike,
                     predictedMagnitude: predictedMagnitude,
                     predictedLength: estimatedSpikeLength,
                     spikeId: thisSpikeId)
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
