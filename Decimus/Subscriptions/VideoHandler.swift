// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

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

/// Callback type for an object.
/// - Parameters:
///    - timestamp: The timestamp of the object, if available.
///    - when: The date when the object was received.
///    - cached: True if the object is from the cache.
///    - headers: The object headers.
///    - usable: True if the object is usable, false if it should be dropped.
typealias ObjectReceived = (_ timestamp: TimeInterval?,
                            _ when: Date,
                            _ cached: Bool,
                            _ headers: QObjectHeaders,
                            _ usable: Bool) -> Void

/// Handles decoding, jitter, and rendering of a video stream.
class VideoHandler: TimeAlignable, CustomStringConvertible {
    // swiftlint:disable:this type_body_length
    private static let logger = DecimusLogger(VideoHandler.self)

    /// The current configuration in use.
    let config: VideoCodecConfig
    /// The full track name identifiying this stream.
    let fullTrackName: FullTrackName

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
        var callbacks: [Int: ObjectReceived] = [:]
        var currentCallbackToken = 0
    }
    private let callbacks = Mutex<Callbacks>(.init())

    var description = "VideoHandler"
    private let participantId: ParticipantId
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let participant = Mutex<VideoParticipant?>(nil)

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
         activeSpeakerStats: ActiveSpeakerStats?) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }
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
        super.init()
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
                                                slidingWindowTime: self.jitterBufferConfig.window)
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
                if self.activeSpeakerStats != nil {
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
                        Self.logger.error("Failed to enqueue decoded sample: \(error)")
                    }
                }
            }
        }
    }

    deinit {
        self.dequeueTask?.cancel()
        Self.logger.debug("Deinit")
    }

    /// Register to receive notifications of an object being received.
    /// - Parameter callback: Callback to be called.
    /// - Returns: Token for unregister.
    func registerCallback(_ callback: @escaping ObjectReceived) -> Int {
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
    func objectReceived(_ objectHeaders: QObjectHeaders,
                        data: Data,
                        extensions: [NSNumber: Data]?,
                        when: Date,
                        cached: Bool,
                        drop: Bool) {
        guard !drop else {
            // Not usable, but notify receipt.
            let toCall: [ObjectReceived] = self.callbacks.withLock { Array($0.callbacks.values) }
            for callback in toCall {
                callback(nil, when, cached, objectHeaders, false)
            }
            guard self.simulreceive != .enable else { return }
            DispatchQueue.main.async {
                guard let participant = self.participant.get() else { return }
                participant.received(when: when, usable: false)
            }
            return
        }

        do {
            // Pull LOC data out of headers.
            guard let extensions = extensions else {
                Self.logger.warning("Missing expected LOC headers")
                return
            }
            let loc = try LowOverheadContainer(from: extensions)
            guard let sequence = loc.sequence else {
                Self.logger.error("Video needs LOC sequence number set")
                return
            }
            guard let frame = try self.depacketize(fullTrackName: self.fullTrackName,
                                                   data: data,
                                                   groupId: objectHeaders.groupId,
                                                   objectId: objectHeaders.objectId,
                                                   sequenceNumber: sequence,
                                                   timestamp: loc.timestamp) else {
                Self.logger.warning("No video data in object")
                return
            }

            guard let timestamp = frame.samples.first?.presentationTimeStamp.seconds else {
                Self.logger.error("Missing expected timestamp")
                return
            }

            if let measurement = self.measurement?.measurement,
               self.granularMetrics {
                Task(priority: .utility) {
                    await measurement.timestamp(timestamp: timestamp, when: when, cached: cached)
                }
            }

            // Notify interested parties of this object.
            let toCall: [ObjectReceived] = self.callbacks.withLock { Array($0.callbacks.values) }
            for callback in toCall {
                callback(timestamp, when, cached, objectHeaders, true)
            }

            // TODO: This can be inlined here.
            try self.submitEncodedData(frame, from: when, cached: cached)
        } catch {
            Self.logger.error("Failed to handle obj recv: \(error.localizedDescription)")
        }
    }

    // MARK: Implementation.

    /// Allows frames to be played from the buffer.
    func play() {
        guard self.jitterBufferConfig.mode == .interval else { return }
        guard let buffer = self.jitterBuffer else {
            Self.logger.error("Set play with no buffer")
            return
        }
        buffer.startPlaying()
    }

    /// Pass an encoded video frame to this video handler.
    /// - Parameter data Encoded H264 frame data.
    /// - Parameter groupId The group.
    /// - Parameter objectId The object in the group.
    /// - Parameter cached True if this object is from the cache (not live).
    func submitEncodedData(_ frame: DecimusVideoFrame, from: Date, cached: Bool) throws {
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
                try jitterBuffer.write(item: item, from: from)
            } catch JitterBufferError.full {
                Self.logger.warning("Didn't enqueue as queue was full")
            } catch JitterBufferError.old {
                Self.logger.warning("Didn't enqueue as frame was older than last read")
            }
        } else {
            try decode(sample: frame, from: from)
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
                    self.description = self.labelFromSample(namespace: namespace,
                                                            format: format,
                                                            fps: resolvedFps,
                                                            participantId: self.participantId)
                    guard let participant = self.participant.get() else { return }
                    if self.simulreceive != .enable {
                        participant.received(when: from, usable: true)
                    }
                    participant.label = .init(describing: self)
                }
            }
        }

        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? from : nil
            Task(priority: .utility) {
                if let now = now,
                   let presentationTime = frame.samples.first?.presentationTimeStamp {
                    let presentationDate = Date(timeIntervalSince1970: presentationTime.seconds)
                    let age = now.timeIntervalSince(presentationDate)
                    await measurement.measurement.age(age: age, timestamp: now, cached: cached)
                }
                await measurement.measurement.receivedFrame(timestamp: now, idr: frame.objectId == 0, cached: cached)
                let bytes = frame.samples.reduce(into: 0) { $0 += $1.totalSampleSize }
                await measurement.measurement.receivedBytes(received: bytes, timestamp: now, cached: cached)
            }
        }
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
                let now: Date
                if let self = self {
                    now = Date.now

                    // Wait until we expect to have a frame available.
                    let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                    if let pid = self.dequeueBehaviour as? PIDDequeuer {
                        pid.currentDepth = jitterBuffer.getDepth()
                        waitTime = self.dequeueBehaviour!.calculateWaitTime(from: now)
                    } else {
                        guard let duration = self.duration else {
                            Self.logger.error("Missing duration")
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
                    if let item: DecimusVideoFrameJitterItem = self.jitterBuffer!.read(from: now) {
                        if self.granularMetrics,
                           let measurement = self.measurement?.measurement,
                           let time = self.calculateWaitTime(item: item) {
                            Task(priority: .utility) {
                                await measurement.frameDelay(delay: -time, metricsTimestamp: now)
                            }
                        }

                        // TODO: Cleanup the need for this regen.
                        // TODO: Thread-safety for current format.
                        let okay = item.frame.samples.allSatisfy { $0.formatDescription != nil }
                        do {
                            let frame = okay ? item.frame : try self.regen(item.frame, format: self.currentFormat)
                            try self.decode(sample: frame, from: now)
                        } catch {
                            Self.logger.warning("Failed to write to decoder: \(error.localizedDescription)")
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
                    Self.logger.warning("Missing expected participant")
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
                Self.logger.warning("Couldn't set display immediately attachment")
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
                Self.logger.error("Could not enqueue sample: \(error)")
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
                Self.logger.error("Could not flush layer: \(error)")
            }
            Self.logger.debug("Flushing display layer")
            self.startTimeSet = false
        }
    }

    private func labelFromSample(namespace: String, format: CMFormatDescription, fps: UInt16, participantId: ParticipantId) -> String {
        let size = format.dimensions
        return "\(namespace): \(String(describing: config.codec)) \(size.width)x\(size.height) \(fps)fps \(Float(config.bitrate) / pow(10, 6))Mbps \(participantId)"
    }

    private func depacketize(fullTrackName: FullTrackName,
                             data: Data,
                             groupId: UInt64,
                             objectId: UInt64,
                             sequenceNumber: UInt64,
                             timestamp: Date) throws -> DecimusVideoFrame? {
        #if DEBUG
        guard self.config.codec != .mock else {
            return try self.mockedFrame(data: data, timestamp: timestamp, groupId: groupId, objectId: objectId)
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
                Self.logger.warning("Failed to parse custom SEI: \(error.localizedDescription)")
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
                                          presentationTimeStamp: .init(value: CMTimeValue(timestamp.timeIntervalSince1970 * 1_000_000),
                                                                       timescale: 1_000_000),
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
    private func mockedFrame(data: Data, timestamp: Date, groupId: UInt64, objectId: UInt64) throws -> DecimusVideoFrame {
        var copy = data
        let sample = try copy.withUnsafeMutableBytes { bytes in
            let timeInfo = CMSampleTimingInfo(duration: .invalid,
                                              presentationTimeStamp: .init(value: CMTimeValue(timestamp.timeIntervalSince1970 * 1_000_000),
                                                                           timescale: 1_000_000),
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
