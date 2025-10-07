// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

// swiftlint:disable file_length

import AVFoundation
import Synchronization

enum DecimusVideoRotation: UInt8 {
    case portrait = 1
    case portraitUpsideDown = 2
    case landscapeRight = 3
    case landscapeLeft = 4
}

struct VideoHelpers {
    let utilities: VideoUtilities
    let seiData: ApplicationSeiData
}

/// Information about a received object.
struct ObjectReceived {
    /// The timestamp of the object, if available.
    let timestamp: TimeInterval?
    /// The time when the object was received.
    let when: Ticks
    /// True if the object is from the cache.
    let cached: Bool
    /// The headers of the object.
    let headers: QObjectHeaders
    /// True if the object is usable, false if it should be dropped.
    let usable: Bool
    /// The publish timestamp, if available.
    let publishTimestamp: Date?
}

/// Callback type for an object.
/// - Parameter details: The details of the object received.
typealias ObjectReceivedCallback = (_ details: ObjectReceived) -> Void

/// Handles decoding, jitter, and rendering of a video stream.
class VideoHandler: TimeAlignable, CustomStringConvertible { // swiftlint:disable:this type_body_length
    /// The current configuration in use.
    let config: VideoCodecConfig
    /// The full track name identifiying this stream.
    let fullTrackName: FullTrackName

    private let logger: DecimusLogger
    private var decoder: VTDecoder?
    private let participants: VideoParticipants
    private let measurement: MeasurementRegistration<VideoHandlerMeasurement>?
    private var lastGroup: UInt64?
    private var lastObject: UInt64?
    private let namegate = SequentialObjectBlockingNameGate()
    private let videoBehaviour: VideoBehaviour
    private let reliable: Bool
    private let granularMetrics: Bool
    private var dequeueTask: Task<(), Never>?
    private var dequeueBehaviour: VideoDequeuer?
    private let jitterBufferConfig: JitterBuffer.Config
    var orientation: DecimusVideoRotation? {
        let result = atomicOrientation.load(ordering: .acquiring)
        return result == 0 ? nil : .init(rawValue: result)
    }
    var verticalMirror: Bool {
        atomicMirror.load(ordering: .acquiring)
    }
    private let atomicOrientation = Atomic<UInt8>(0)
    private let atomicMirror = Atomic<Bool>(false)
    private var currentFormat: CMFormatDescription?
    private var startTimeSet = false
    private let metricsSubmitter: MetricsSubmitter?
    private let simulreceive: SimulreceiveMode
    let lastDecodedImage = Mutex<AvailableImage?>(nil)
    private var lastFps: UInt16?
    private var lastDimensions: CMVideoDimensions?

    private var duration: TimeInterval? = 0
    private let variances: VarianceCalculator

    private struct Callbacks {
        var callbacks: [Int: ObjectReceivedCallback] = [:]
        var currentCallbackToken = 0
    }
    private let callbacks = Mutex<Callbacks>(.init())

    var description = "VideoHandler"
    private let participantId: ParticipantId
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let participant = Mutex<VideoParticipant?>(nil)
    private let handlerConfig: Config
    private let detector: WiFiScanDetector?
    private var lastReceived: Ticks?
    private let jitterCalculation: RFC3550Jitter

    // Wi-Fi scan jitter buffer ramping state.
    enum RampState {
        case none, up(Date), spike(Date), down(Date)
    }
    private var targetJitterDepth: TimeInterval
    private var rampState = RampState.none
    private let spikeDepth: TimeInterval = 0.200 // 200ms fallback
    private let rampDuration: TimeInterval = 1.0  // 1s
    private var predictable = false  // Don't predict if we can't
    private var lastSpikeDetectionTime: Date?  // Track when we last detected elevated latency
    private var spikeToken: Int?
    private var lastSpikeRespondedTo: Int?
    private var currentSpikeLength: TimeInterval?

    /// Configuration for the handler.
    struct Config {
        /// True to calculate end-to-end latency.
        let calculateLatency: Bool
        /// True to use MoQ MI
        let mediaInterop: Bool
    }

    /// Create a new video handler.
    /// - Parameters:
    ///     - namespace: The namespace for this video stream.
    ///     - config: Codec configuration for this video stream.
    ///     - participants: Video participants dependency for rendering.
    ///     - metricsSubmitter: If present, a submitter to record metrics through.
    ///     - videoBehaviour: Behaviour mode used for making decisions about valid group/object values.
    ///     - reliable: True if this stream should be considered to be reliable (in order, no loss).
    ///     - granularMetrics: True to record per frame / operation metrics at a performance cost.
    ///     - jitterBufferConfig: Requested configuration for jitter handling.
    ///     - simulreceive: The mode to operate in if any sibling streams are present.
    ///     - handlerConfig: Configuration for this handler.
    /// - Throws: Simulreceive cannot be used with a jitter buffer mode of `layer`.
    init(fullTrackName: FullTrackName,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         videoBehaviour: VideoBehaviour,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: JitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         variances: VarianceCalculator,
         participantId: ParticipantId,
         subscribeDate: Date,
         joinDate: Date,
         activeSpeakerStats: ActiveSpeakerStats?,
         handlerConfig: Config,
         wifiDetector: WiFiScanDetector?) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }
        self.logger = .init(VideoHandler.self, prefix: "\(fullTrackName)")
        self.fullTrackName = fullTrackName
        self.config = config
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            let measurement = VideoHandler.VideoHandlerMeasurement(namespace: "\(self.fullTrackName)")
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.videoBehaviour = videoBehaviour
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.metricsSubmitter = metricsSubmitter
        self.variances = variances
        self.participantId = participantId
        self.activeSpeakerStats = activeSpeakerStats
        self.handlerConfig = handlerConfig
        self.detector = wifiDetector
        self.targetJitterDepth = self.jitterBufferConfig.minDepth
        self.jitterCalculation = .init(identifier: "\(self.fullTrackName)",
                                       submitter: metricsSubmitter)
        super.init()
        self.spikeToken = self.detector?.registerNotifyCallback { [weak self] in
            guard let self = self else { return }
            self.predictable = true
        }
        if self.simulreceive != .enable {
            Task {
                let participant = try await MainActor.run {
                    let existing = self.participant.get()
                    guard existing == nil else { return VideoParticipant?.none }
                    return try VideoParticipant(id: "\(self.fullTrackName)",
                                                startDate: joinDate,
                                                subscribeDate: subscribeDate,
                                                videoParticipants: self.participants,
                                                participantId: self.participantId,
                                                activeSpeakerStats: self.activeSpeakerStats,
                                                config: .init(calculateLatency: self.handlerConfig.calculateLatency,
                                                              slidingWindowTime: self.jitterBufferConfig.window))

                }
                guard let participant = participant else { return }
                self.participant.withLock { $0 = participant }
            }
        } else {
            self.participant.clear()
        }

        if jitterBufferConfig.mode != .layer {
            // Create the decoder.
            self.decoder = .init(config: self.config) { [weak self] sample in
                guard let self = self else { return }

                // Calculate / report E2E latency.
                let endToEndLatency: TimeInterval?
                let now = Date.now
                if self.handlerConfig.calculateLatency {
                    let presentationTime = sample.presentationTimeStamp.seconds
                    let presentationDate = Date(timeIntervalSince1970: presentationTime)
                    let age = now.timeIntervalSince(presentationDate)
                    endToEndLatency = age
                    if self.granularMetrics,
                       let measurement = self.measurement?.measurement {
                        Task(priority: .utility) {
                            await measurement.decodedAge(age: age, timestamp: now)
                        }
                    }
                } else {
                    endToEndLatency = nil
                }

                if simulreceive != .none {
                    _ = self.variances.calculateSetVariance(timestamp: sample.presentationTimeStamp.seconds,
                                                            now: now)
                    self.lastDecodedImage.withLock { $0 = .init(image: sample,
                                                                fps: UInt(self.config.fps),
                                                                discontinous: sample.discontinous) }
                }
                if let participant = self.participant.get() {
                    // Enqueue for rendering.
                    do {
                        try self.enqueueSample(sample: sample,
                                               orientation: self.orientation,
                                               verticalMirror: self.verticalMirror,
                                               from: now,
                                               participant: participant,
                                               endToEndLatency: endToEndLatency)
                    } catch {
                        self.logger.error("Failed to enqueue decoded sample: \(error)")
                    }
                }
            }
        }
    }

    deinit {
        self.dequeueTask?.cancel()
        if let spikeToken = self.spikeToken {
            self.detector!.removeNotifyCallback(token: spikeToken)
        }
        self.logger.debug("Deinit")
    }

    /// Register to receive notifications of an object being received.
    /// - Parameter callback: Callback to be called.
    /// - Returns: Token for unregister.
    func registerCallback(_ callback: @escaping ObjectReceivedCallback) -> Int {
        self.callbacks.withLock { callbacks in
            callbacks.currentCallbackToken += 1
            callbacks.callbacks[callbacks.currentCallbackToken] = callback
            return callbacks.currentCallbackToken
        }
    }

    /// Unregister a previously registered callback.
    /// - Parameter token: Token from a ``registerCallback(_:)`` call.
    func unregisterCallback(_ token: Int) {
        _ = self.callbacks.withLock { $0.callbacks.removeValue(forKey: token) }
    }

    // MARK: Callbacks.

    /// Pass an encoded video frame to this handler.
    /// - Parameter objectHeaders: The object headers.
    /// - Parameter data: Encoded frame data.
    /// - Parameter extensions: Optional extensions.
    /// - Parameter when: Date when the object was received.
    /// - Parameter cached: True if this object is from the cache (not live).
    /// - Parameter drop: True if this object should be dropped.
    func objectReceived(_ objectHeaders: QObjectHeaders, // swiftlint:disable:this cyclomatic_complexity function_body_length
                        data: Data,
                        extensions: [NSNumber: Data]?,
                        when: Ticks,
                        cached: Bool,
                        drop: Bool) {
        if let lastReceived = self.lastReceived {
            let interval = when.timeIntervalSince(lastReceived)
            if let detector = self.detector {
                detector.addIntervalMeasurement(interval: interval,
                                                identifier: "\(self.fullTrackName)",
                                                timestamp: when.hostDate)
            }
        }
        self.lastReceived = when

        // Spike prediction and jitter buffer ramping.
        if let detector = self.detector {
            let prediction = detector.predictNextScan(from: when.hostDate)
            self.updateJitterBufferForWiFiScan(prediction: prediction, timestamp: when.hostDate)
        }

        guard !drop else {
            // Not usable, but notify receipt.
            let toCall: [ObjectReceivedCallback] = self.callbacks.withLock { Array($0.callbacks.values) }
            let details = ObjectReceived(timestamp: nil,
                                         when: when,
                                         cached: cached,
                                         headers: objectHeaders,
                                         usable: false,
                                         publishTimestamp: nil)
            for callback in toCall {
                callback(details)
            }
            guard self.simulreceive != .enable else { return }
            DispatchQueue.main.async {
                guard let participant = self.participant.get() else { return }
                participant.received(details)
            }
            return
        }

        // Video needs extensions to be present.
        guard let extensions = extensions else {
            self.logger.error("Missing expected header extensions")
            return
        }

        let encoded: Data
        let presentationTimestamp: CMTime
        let sequence: UInt64
        do {
            if self.handlerConfig.mediaInterop {
                let metadata = switch try extensions.getHeader(.videoH264AVCCMetadata) {
                case .videoH264AVCCMetadata(let metadata):
                    metadata
                default:
                    throw "Bad header extension"
                }
                presentationTimestamp = .init(value: CMTimeValue(metadata.ptsTimestamp.value),
                                              timescale: CMTimeScale(metadata.timebase.value))
                sequence = metadata.seqId.value

                let extradata: Data? = switch try extensions.getHeader(.videoH264AVCCExtradata) {
                case .videoH264AVCCExtradata(let data):
                    data
                case nil:
                    nil
                default:
                    throw "Bad header extension"
                }

                if let extradata = extradata {
                    encoded = extradata + data
                } else {
                    encoded = data
                }
            } else {
                // Data.
                encoded = data

                // Sequence number.
                guard let sequenceData = try? extensions.getHeader(.sequenceNumber),
                      case .sequenceNumber(let seq) = sequenceData else {
                    self.logger.error("Video needs LOC sequence number set")
                    return
                }
                sequence = seq

                // Timestamp.
                guard let presentationTimestampData = try? extensions.getHeader(.captureTimestamp),
                      case .captureTimestamp(let timestamp) = presentationTimestampData else {
                    self.logger.error("Video needs LOC timestamp set")
                    return
                }
                presentationTimestamp = .init(value: .init(timestamp.timeIntervalSince1970 * microsecondsPerSecond),
                                              timescale: CMTimeScale(microsecondsPerSecond))
            }

            guard let frame = try self.depacketize(fullTrackName: self.fullTrackName,
                                                   data: encoded,
                                                   groupId: objectHeaders.groupId,
                                                   objectId: objectHeaders.objectId,
                                                   sequenceNumber: sequence,
                                                   presentation: presentationTimestamp) else {
                self.logger.error("Failed to depacketize video frame")
                return
            }

            let presentationInterval = presentationTimestamp.seconds

            // Drive base target depth from smoothed RFC3550 jitter.
            if self.jitterBufferConfig.adaptive {
                self.jitterCalculation.record(timestamp: presentationInterval, arrival: when.hostDate)
                let newTarget = max(self.jitterBufferConfig.minDepth, self.jitterCalculation.smoothed * 3)
                if let jitterBuffer = self.jitterBuffer {
                    let existing = jitterBuffer.getBaseTargetDepth()
                    let change = (newTarget - existing) / existing
                    if change > 0 || change < -0.1 {
                        jitterBuffer.setBaseTargetDepth(newTarget)
                    }
                }
            }

            if let measurement = self.measurement?.measurement,
               self.granularMetrics {
                Task(priority: .utility) {
                    await measurement.timestamp(timestamp: presentationInterval, when: when.hostDate, cached: cached)
                }
            }

            let publishTimestamp: Date?
            if let publishTimestampDate = try? extensions.getHeader(.publishTimestamp),
               case .publishTimestamp(let extracted) = publishTimestampDate {
                publishTimestamp = extracted
            } else {
                publishTimestamp = nil
            }

            // Notify interested parties of this object.
            let toCall: [ObjectReceivedCallback] = self.callbacks.withLock { Array($0.callbacks.values) }
            let details = ObjectReceived(timestamp: presentationInterval,
                                         when: when,
                                         cached: cached,
                                         headers: objectHeaders,
                                         usable: true,
                                         publishTimestamp: publishTimestamp)
            for callback in toCall {
                callback(details)
            }

            try self.submitEncodedData(frame, details: details)
        } catch {
            self.logger.error("Failed to handle obj recv: \(error.localizedDescription)")
        }
    }

    // MARK: Implementation.

    /// Allows frames to be played from the buffer.
    func play() {
        guard self.jitterBufferConfig.mode == .interval else { return }
        guard let buffer = self.jitterBuffer else {
            self.logger.error("Set play with no buffer")
            return
        }
        buffer.startPlaying()
    }

    /// Pass an encoded video frame to this video handler.
    /// - Parameter frame: Encoded video frame.
    /// - Parameter details: Details about the received object.
    private func submitEncodedData(_ frame: DecimusVideoFrame, details: ObjectReceived) throws {
        // Do we need to create a jitter buffer?
        if self.jitterBuffer == nil,
           self.jitterBufferConfig.mode != .layer,
           self.jitterBufferConfig.mode != .none {
            // Create the video jitter buffer.
            try createJitterBuffer(frame: frame, reliable: self.reliable)
            assert(self.dequeueTask == nil)
            createDequeueTask()
        }

        // Do we need to copy the frame data?
        let copy = self.jitterBuffer != nil || self.jitterBufferConfig.mode == .layer
        let frame: DecimusVideoFrame = copy ? try .init(copy: frame) : frame

        // Either write the frame to the jitter buffer or otherwise decode it.
        if let jitterBuffer = self.jitterBuffer {
            let item = try DecimusVideoFrameJitterItem(frame)
            do {
                try jitterBuffer.write(item: item, from: details.when.hostDate)
            } catch JitterBufferError.full {
                self.logger.warning("Didn't enqueue as queue was full")
            } catch JitterBufferError.old {
                self.logger.warning("Didn't enqueue as frame was older than last read")
            }
        } else {
            try decode(sample: frame, from: details.when.hostDate)
        }

        // Do we need to update the label?
        if let first = frame.samples.first {
            let resolvedFps: UInt16
            if let fps = frame.fps {
                resolvedFps = UInt16(fps)
            } else {
                resolvedFps = self.config.fps
            }

            if let format = first.formatDescription,
               resolvedFps != self.lastFps || format.dimensions != self.lastDimensions {
                self.lastFps = resolvedFps
                self.lastDimensions = format.dimensions
                DispatchQueue.main.async {
                    let namespace = "\(self.fullTrackName)"
                    self.description = self.labelFromSample(format: format,
                                                            fps: resolvedFps,
                                                            participantId: self.participantId)
                    guard let participant = self.participant.get() else { return }
                    if self.simulreceive != .enable {
                        participant.received(details)
                    }
                    participant.label = .init(describing: self)
                }
            }
        }

        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? details.when.hostDate : nil
            Task(priority: .utility) {
                if let now = now,
                   let presentationTime = frame.samples.first?.presentationTimeStamp {
                    let presentationDate = Date(timeIntervalSince1970: presentationTime.seconds)
                    let age = now.timeIntervalSince(presentationDate)
                    await measurement.measurement.age(age: age, timestamp: now, cached: details.cached)
                }
                await measurement.measurement.receivedFrame(timestamp: now,
                                                            idr: frame.objectId == 0,
                                                            cached: details.cached)
                let bytes = frame.samples.reduce(into: 0) { $0 += $1.totalSampleSize }
                await measurement.measurement.receivedBytes(received: bytes, timestamp: now, cached: details.cached)
            }
        }
    }

    /// Update jitter buffer depth based on Wi-Fi scan prediction
    private func updateJitterBufferForWiFiScan(prediction: Prediction,
                                               timestamp: Date) {
        // Wait until we're in a position to predict.
        guard let jitterBuffer = self.jitterBuffer,
              self.predictable else { return }

        let timeToScan = prediction.timeToScan
        let predictedMagnitude = prediction.predictedMagnitude
        let baseDepth = jitterBuffer.getBaseTargetDepth()

        // Resolve current state.
        let rampStartTime: Date
        switch self.rampState {
        case .none:
            guard let timeToScan = timeToScan,
                  timeToScan <= self.rampDuration,
                  predictedMagnitude > baseDepth else { return } // Nothing to do.
            if let lastSpikeRespondedTo,
               prediction.spikeId <= lastSpikeRespondedTo {
                // Already responded to this prediction.
                return
            }

            // Start ramp up in prep for scan.
            self.logger.info("📡 Ramping up - Spike in \(timeToScan)s, predicted max interval \(predictedMagnitude * 1000)ms")
            self.lastSpikeRespondedTo = prediction.spikeId
            self.currentSpikeLength = prediction.predictedLength
            self.rampState = .up(timestamp)
            rampStartTime = timestamp
            self.targetJitterDepth = predictedMagnitude + baseDepth
        case .up(let startTime):
            guard timestamp.timeIntervalSince(startTime) < self.rampDuration else {
                self.logger.info("📡 Ramp up complete")
                self.rampState = .spike(timestamp)
                return // Stay at spike depth.
            }

            // Still ramping up, no change.
            rampStartTime = startTime
        case .spike(let startTime):
            guard timestamp.timeIntervalSince(startTime) > self.currentSpikeLength! else { return }
            // We're done, start ramp down.
            self.logger.info("📡 Ramping down - Spike should be over")
            self.rampState = .down(timestamp)
            rampStartTime = timestamp
        case .down(let startTime):
            rampStartTime = startTime
            // Have we finished ramping down?
            if timestamp.timeIntervalSince(startTime) >= self.rampDuration {
                self.logger.info("📡 Ramp down complete")
                self.rampState = .none
                self.currentSpikeLength = nil
            }
        }

        // Calculate new required depth.
        let rampProgress = min(timestamp.timeIntervalSince(rampStartTime) / self.rampDuration, 100.0)
        let adjustment = switch self.rampState {
        case .up:
            // Ramp up from base to spike depth.
            (self.targetJitterDepth - baseDepth) * rampProgress
        case .down:
            // Ramp from spike depth back to base.
            (self.targetJitterDepth - baseDepth) * (1 - rampProgress)
        case .none:
            TimeInterval(0)
        case .spike:
            predictedMagnitude // Should never happen.
        }

        // Apply the new depth.
        jitterBuffer.setTargetAdjustment(adjustment)
    }

    private func createJitterBuffer(frame: DecimusVideoFrame, reliable: Bool) throws {
        let remoteFPS: UInt16
        if let fps = frame.fps {
            remoteFPS = UInt16(fps)
        } else {
            remoteFPS = self.config.fps
        }

        // We have what we need to configure the PID dequeuer if using.
        let duration = 1 / Double(remoteFPS)
        assert(self.dequeueBehaviour == nil)
        if jitterBufferConfig.mode == .pid {
            self.dequeueBehaviour = PIDDequeuer(targetDepth: jitterBufferConfig.minDepth,
                                                frameDuration: duration,
                                                kp: 0.01,
                                                ki: 0.001,
                                                kd: 0.001)
        }

        // Create the video jitter buffer.
        // swiftlint:disable force_cast
        let handlers = CMBufferQueue.Handlers { builder in
            builder.compare {
                let first = $0 as! DecimusVideoFrameJitterItem
                let second = $1 as! DecimusVideoFrameJitterItem
                let seq1 = first.sequenceNumber
                let seq2 = second.sequenceNumber
                if seq1 < seq2 {
                    return .compareLessThan
                } else if seq1 > seq2 {
                    return .compareGreaterThan
                } else if seq1 == seq2 {
                    return .compareEqualTo
                }
                assert(false)
                return .compareLessThan
            }
            builder.getDecodeTimeStamp {
                ($0 as! DecimusVideoFrameJitterItem).frame.samples.first?.decodeTimeStamp ?? .invalid
            }
            builder.getDuration {
                ($0 as! DecimusVideoFrameJitterItem).frame.samples.first?.duration ?? .invalid
            }
            builder.getPresentationTimeStamp {
                ($0 as! DecimusVideoFrameJitterItem).frame.samples.first?.presentationTimeStamp ?? .invalid
            }
            builder.getSize {
                ($0 as! DecimusVideoFrameJitterItem).frame.samples.reduce(0) { $0 + $1.totalSampleSize }
            }
            builder.isDataReady {
                ($0 as! DecimusVideoFrameJitterItem).frame.samples.allSatisfy { $0.dataReadiness == .ready }
            }
        }
        // swiftlint:enable force_cast
        self.jitterBuffer = try .init(identifier: "\(self.fullTrackName)",
                                      metricsSubmitter: self.metricsSubmitter,
                                      minDepth: self.jitterBufferConfig.minDepth,
                                      capacity: Int(floor(self.jitterBufferConfig.capacity / duration)),
                                      handlers: handlers,
                                      playingFromStart: false)
        self.duration = duration
    }

    private func createDequeueTask() {
        // Start the frame dequeue task.
        self.dequeueTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                let waitTime: TimeInterval
                let now: Ticks
                if let self = self {
                    now = .now

                    // Wait until we expect to have a frame available.
                    let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                    if let pid = self.dequeueBehaviour as? PIDDequeuer {
                        pid.currentDepth = jitterBuffer.getDepth()
                        waitTime = self.dequeueBehaviour!.calculateWaitTime(from: now.hostDate)
                    } else {
                        guard let duration = self.duration else {
                            self.logger.error("Missing duration")
                            return
                        }
                        waitTime = calculateWaitTime(from: now) ?? duration
                    }
                } else {
                    return
                }

                // Sleep without holding a strong reference.
                if waitTime > 0 {
                    try? await Task.sleep(for: .seconds(waitTime),
                                          tolerance: .seconds(waitTime / 2),
                                          clock: .continuous)
                }

                // Regain our strong reference after sleeping.
                if let self = self {
                    // Attempt to dequeue a frame.
                    if let item: DecimusVideoFrameJitterItem = self.jitterBuffer!.read(from: now.hostDate) {
                        if self.granularMetrics,
                           let measurement = self.measurement?.measurement,
                           let time = self.calculateWaitTime(item: item, from: now) {
                            Task(priority: .utility) {
                                await measurement.frameDelay(delay: -time, metricsTimestamp: now.hostDate)
                            }
                        }

                        // TODO: Cleanup the need for this regen.
                        // TODO: Thread-safety for current format.
                        let okay = item.frame.samples.allSatisfy { $0.formatDescription != nil }
                        do {
                            let frame = okay ? item.frame : try self.regen(item.frame, format: self.currentFormat)
                            try self.decode(sample: frame, from: now.hostDate)
                        } catch {
                            self.logger.warning("Failed to write to decoder: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Regenerate the frame to have the given format.
    private func regen(_ frame: DecimusVideoFrame, format: CMFormatDescription?) throws -> DecimusVideoFrame {
        guard let format = format else { throw "Missing expected format" }
        let samples = try frame.samples.map { sample in
            try CMSampleBuffer(dataBuffer: sample.dataBuffer,
                               formatDescription: format,
                               numSamples: sample.numSamples,
                               sampleTimings: sample.sampleTimingInfos(),
                               sampleSizes: sample.sampleSizes())
        }
        return .init(samples: samples,
                     groupId: frame.groupId,
                     objectId: frame.objectId,
                     sequenceNumber: frame.sequenceNumber,
                     fps: frame.fps,
                     orientation: frame.orientation,
                     verticalMirror: frame.verticalMirror)
    }

    private func decode(sample: DecimusVideoFrame, from: Date) throws {
        // Should we feed this frame to the decoder?
        // get groupId and objectId from the frame (1st frame)
        let groupId = sample.groupId
        let objectId = sample.objectId
        let gateResult = namegate.handle(groupId: groupId,
                                         objectId: objectId,
                                         lastGroup: self.lastGroup,
                                         lastObject: self.lastObject)
        guard gateResult || self.videoBehaviour != .freeze else {
            // If there's a discontinuity and we want to freeze, we're done.
            return
        }

        if gateResult {
            // Update to track continuity.
            self.lastGroup = groupId
            self.lastObject = objectId
        } else {
            // Mark discontinous.
            for sample in sample.samples {
                sample.discontinous = true
            }
        }

        // Decode.
        for sampleBuffer in sample.samples {
            if self.jitterBufferConfig.mode == .layer {
                guard let participant = self.participant.get() else {
                    self.logger.warning("Missing expected participant")
                    return
                }
                try self.enqueueSample(sample: sampleBuffer,
                                       orientation: sample.orientation,
                                       verticalMirror: sample.verticalMirror,
                                       from: from,
                                       participant: participant,
                                       endToEndLatency: nil)
            } else {
                if let orientation = sample.orientation {
                    self.atomicOrientation.store(orientation.rawValue, ordering: .releasing)
                }
                if let verticalMirror = sample.verticalMirror {
                    self.atomicMirror.store(verticalMirror, ordering: .releasing)
                }
                try decoder!.write(sampleBuffer)
                if self.granularMetrics,
                   let measurement = self.measurement?.measurement {
                    let written = Date.now
                    let presentationTime = sampleBuffer.presentationTimeStamp
                    Task(priority: .utility) {
                        let presentationDate = Date(timeIntervalSince1970: presentationTime.seconds)
                        let age = written.timeIntervalSince(presentationDate)
                        await measurement.writeDecoder(age: age, timestamp: written)
                    }
                }
            }
        }
    }

    private func enqueueSample(sample: CMSampleBuffer,
                               orientation: DecimusVideoRotation?,
                               verticalMirror: Bool?,
                               from: Date,
                               participant: VideoParticipant,
                               endToEndLatency: TimeInterval?) throws {
        if let measurement = self.measurement,
           self.jitterBufferConfig.mode != .layer {
            let now: Date? = self.granularMetrics ? from : nil
            Task(priority: .utility) {
                await measurement.measurement.decodedFrame(timestamp: now)
            }
        }

        if self.jitterBufferConfig.mode != .layer {
            // We're taking care of time already, show immediately.
            if sample.sampleAttachments.count > 0 {
                sample.sampleAttachments[0][.displayImmediately] = true
            } else {
                self.logger.warning("Couldn't set display immediately attachment")
            }
        }

        // Enqueue the sample on the main thread.
        DispatchQueue.main.async {
            do {
                // Set the layer's start time to the first sample's timestamp minus the target depth.
                if !self.startTimeSet {
                    try self.setLayerStartTime(layer: participant.view.layer!, time: sample.presentationTimeStamp)
                    self.startTimeSet = true
                }
                try participant.enqueue(sample,
                                        transform: orientation?.toTransform(verticalMirror!),
                                        when: from,
                                        endToEndLatency: endToEndLatency)
                if self.granularMetrics,
                   let measurement = self.measurement {
                    let timestamp = sample.presentationTimeStamp.seconds
                    Task(priority: .background) {
                        await measurement.measurement.enqueuedFrame(frameTimestamp: timestamp, metricsTimestamp: from)
                    }
                }
            } catch {
                self.logger.error("Could not enqueue sample: \(error)")
            }
        }
    }

    private func setLayerStartTime(layer: AVSampleBufferDisplayLayer, time: CMTime) throws {
        guard Thread.isMainThread else {
            throw "Should be called from the main thread"
        }
        let timebase = try CMTimebase(sourceClock: .hostTimeClock)
        let startTime: CMTime
        if self.jitterBufferConfig.mode == .layer {
            let delay = CMTime(seconds: self.jitterBufferConfig.minDepth,
                               preferredTimescale: 1000)
            startTime = CMTimeSubtract(time, delay)
        } else {
            startTime = time
        }
        try timebase.setTime(startTime)
        try timebase.setRate(1.0)
        layer.controlTimebase = timebase
    }

    private func flushDisplayLayer() {
        guard let participant = self.participant.get() else { return }
        DispatchQueue.main.async {
            do {
                try participant.view.flush()
            } catch {
                self.logger.error("Could not flush layer: \(error)")
            }
            self.logger.debug("Flushing display layer")
            self.startTimeSet = false
        }
    }

    private func labelFromSample(format: CMFormatDescription, fps: UInt16, participantId: ParticipantId) -> String {
        let size = format.dimensions
        return "\(self.fullTrackName) \(String(describing: config.codec)) \(size.width)x\(size.height) \(fps)fps \(Float(config.bitrate) / pow(10, 6))Mbps \(participantId)"
    }

    private func depacketize(fullTrackName: FullTrackName,
                             data: Data,
                             groupId: UInt64,
                             objectId: UInt64,
                             sequenceNumber: UInt64,
                             presentation: CMTime) throws -> DecimusVideoFrame? {
        #if DEBUG
        guard self.config.codec != .mock else {
            return try self.mockedFrame(data: data,
                                        presentation: presentation,
                                        groupId: groupId,
                                        objectId: objectId)
        }
        #endif

        let helpers: VideoHelpers = try {
            switch self.config.codec {
            case .h264:
                return .init(utilities: H264Utilities(), seiData: ApplicationH264SEIs())
            case .hevc:
                return .init(utilities: HEVCUtilities(), seiData: ApplicationHEVCSEIs())
            default:
                throw "Unsupported codec"
            }
        }()

        // Depacketize.
        var extractedFormat: CMFormatDescription?
        var seis: [ApplicationSEI] = []
        let buffers = try helpers.utilities.depacketize(data, format: &extractedFormat, copy: false) {
            do {
                let parser = ApplicationSeiParser(helpers.seiData)
                if let sei = try parser.parse(encoded: $0) {
                    seis.append(sei)
                }
            } catch {
                self.logger.warning("Failed to parse custom SEI: \(error.localizedDescription)")
            }
        }
        let format: CMFormatDescription?
        if let extractedFormat = extractedFormat {
            self.currentFormat = extractedFormat
        }
        format = self.currentFormat

        let sei: ApplicationSEI?
        if seis.count == 0 {
            sei = nil
        } else {
            sei = seis.reduce(ApplicationSEI(timestamp: nil, orientation: nil)) { result, next in
                let timestamp = next.timestamp ?? result.timestamp
                let orientation = next.orientation ?? result.orientation
                return .init(timestamp: timestamp, orientation: orientation)
            }
        }

        guard let buffers = buffers else { return nil }
        let timeInfo = CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: presentation,
                                          decodeTimeStamp: .invalid)

        var samples: [CMSampleBuffer] = []
        for buffer in buffers {
            samples.append(try CMSampleBuffer(dataBuffer: buffer,
                                              formatDescription: format,
                                              numSamples: 1,
                                              sampleTimings: [timeInfo],
                                              sampleSizes: [buffer.dataLength]))
        }

        return .init(samples: samples,
                     groupId: groupId,
                     objectId: objectId,
                     sequenceNumber: sequenceNumber,
                     fps: sei?.timestamp?.fps,
                     orientation: sei?.orientation?.orientation,
                     verticalMirror: sei?.orientation?.verticalMirror)
    }

    #if DEBUG
    private func mockedFrame(data: Data,
                             presentation: CMTime,
                             groupId: UInt64,
                             objectId: UInt64) throws -> DecimusVideoFrame {
        var copy = data
        let sample = try copy.withUnsafeMutableBytes { bytes in
            let timeInfo = CMSampleTimingInfo(duration: .invalid,
                                              presentationTimeStamp: presentation,
                                              decodeTimeStamp: .invalid)
            return try CMSampleBuffer(dataBuffer: try .init(buffer: bytes) { _, _ in },
                                      formatDescription: nil,
                                      numSamples: 1,
                                      sampleTimings: [timeInfo],
                                      sampleSizes: [data.count])
        }
        return DecimusVideoFrame(samples: [sample],
                                 groupId: groupId,
                                 objectId: objectId,
                                 sequenceNumber: 0,
                                 fps: 30,
                                 orientation: nil,
                                 verticalMirror: nil)
    }
    #endif
}

extension DecimusVideoRotation {
    func toTransform(_ verticalMirror: Bool) -> CATransform3D {
        var transform = CATransform3DIdentity
        switch self {
        case .portrait:
            transform = CATransform3DRotate(transform, .pi / 2, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        case .landscapeLeft:
            transform = CATransform3DRotate(transform, .pi, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        case .landscapeRight:
            transform = CATransform3DRotate(transform, -.pi, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, -1.0, 1.0, 1.0)
            }
        case .portraitUpsideDown:
            transform = CATransform3DRotate(transform, -.pi / 2, 0, 0, 1)
            if verticalMirror {
                transform = CATransform3DScale(transform, 1.0, -1.0, 1.0)
            }
        }
        return transform
    }
}

extension CoreMedia.CMVideoDimensions: Swift.Equatable {
    public static func == (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }
}

class DecimusVideoFrameJitterItem: JitterBuffer.JitterItem {
    let frame: DecimusVideoFrame
    let sequenceNumber: UInt64
    let timestamp: CMTime

    init(_ frame: DecimusVideoFrame) throws {
        guard let seq = frame.sequenceNumber,
              let time = frame.samples.first?.presentationTimeStamp else {
            throw "Missing non optional fields"
        }
        self.frame = frame
        self.sequenceNumber = seq
        self.timestamp = time
    }
}
