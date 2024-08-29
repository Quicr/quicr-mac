import AVFoundation
import Atomics
import os

// swiftlint:disable type_body_length

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

typealias ObjectReceived = (_ handler: VideoHandler,
                            _ timestamp: TimeInterval,
                            _ when: Date,
                            _ userData: UnsafeRawPointer) -> Void

/// Handles decoding, jitter, and rendering of a video stream.
class VideoHandler: QSubscribeTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
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
    private var jitterBuffer: VideoJitterBuffer?
    private let granularMetrics: Bool
    private var dequeueTask: Task<(), Never>?
    private var dequeueBehaviour: VideoDequeuer?
    private let jitterBufferConfig: VideoJitterBuffer.Config
    var orientation: DecimusVideoRotation? {
        let result = atomicOrientation.load(ordering: .acquiring)
        return result == 0 ? nil : .init(rawValue: result)
    }
    var verticalMirror: Bool {
        atomicMirror.load(ordering: .acquiring)
    }
    private var atomicOrientation = ManagedAtomic<UInt8>(0)
    private var atomicMirror = ManagedAtomic<Bool>(false)
    private var currentFormat: CMFormatDescription?
    private var startTimeSet = false
    private let metricsSubmitter: MetricsSubmitter?
    private let simulreceive: SimulreceiveMode
    var lastDecodedImage: AvailableImage?
    let lastDecodedImageLock = OSAllocatedUnfairLock()
    private var timestampTimeDiffUs = ManagedAtomic(UInt64.zero)
    private var lastFps: UInt16?
    private var lastDimensions: CMVideoDimensions?

    private var duration: TimeInterval? = 0
    private let variances: VarianceCalculator
    private let callback: ObjectReceived
    private let userData: UnsafeRawPointer

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
         jitterBufferConfig: VideoJitterBuffer.Config,
         simulreceive: SimulreceiveMode,
         variances: VarianceCalculator,
         callback: @escaping ObjectReceived,
         userData: UnsafeRawPointer) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }
        self.fullTrackName = fullTrackName
        self.config = config
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            let measurement = VideoHandler.VideoHandlerMeasurement(namespace: try self.fullTrackName.getNamespace())
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
        self.callback = callback
        self.userData = userData
        
        // TODO: This is unsafe.
        var qFtn: QFullTrackName = .init()
        fullTrackName.get {
            qFtn = $0
        }
        super.init(fullTrackName: qFtn)

        if jitterBufferConfig.mode != .layer {
            // Create the decoder.
            self.decoder = .init(config: self.config) { [weak self] sample in
                guard let self = self else { return }
                let now = Date.now
                if simulreceive != .none {
                    _ = self.variances.calculateSetVariance(timestamp: sample.presentationTimeStamp.seconds,
                                                            now: now)
                    self.lastDecodedImageLock.lock()
                    defer { self.lastDecodedImageLock.unlock() }
                    self.lastDecodedImage = .init(image: sample,
                                                  fps: UInt(self.config.fps),
                                                  discontinous: sample.discontinous)
                }
                if simulreceive != .enable {
                    // Enqueue for rendering.
                    do {
                        try self.enqueueSample(sample: sample,
                                               orientation: self.orientation,
                                               verticalMirror: self.verticalMirror,
                                               from: now)
                    } catch {
                        Self.logger.error("Failed to enqueue decoded sample: \(error)")
                    }
                }
            }
        }
    }

    deinit {
        if self.simulreceive != .enable {
            do {
                self.participants.removeParticipant(identifier: try self.fullTrackName.getNamespace())
            } catch {
                Self.logger.error("Failed to extract FTN namespace")
            }
        }
        self.dequeueTask?.cancel()
    }

    // MARK: Callbacks.

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        Self.logger.info("Subscribe Track Status Changed: \(status)")
    }
    
    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]) {
        Self.logger.info("Got video object: \(objectHeaders.groupId):\(objectHeaders.objectId)")
        let now = Date.now
        do {
            guard let frame = try self.depacketize(fullTrackName: self.fullTrackName,
                                                   data: data,
                                                   groupId: objectHeaders.groupId,
                                                   objectId: objectHeaders.objectId) else {
                Self.logger.warning("No video data in object")
                return
            }

            guard let timestamp = frame.samples.first?.presentationTimeStamp.seconds else {
                Self.logger.error("Missing expected timestamp")
                return
            }

            self.callback(self, timestamp, now, self.userData)

            // TODO: This can be inlined here.
            try self.submitEncodedData(frame, from: now)
        } catch {
            Self.logger.error("Failed to handle obj recv: \(error.localizedDescription)")
        }
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]) {
        Self.logger.error("Not expecting partial objects")
    }

    // MARK: Implementation.

    /// Pass an encoded video frame to this video handler.
    /// - Parameter data Encoded H264 frame data.
    /// - Parameter groupId The group.
    /// - Parameter objectId The object in the group.
    func submitEncodedData(_ frame: DecimusVideoFrame, from: Date) throws {
        // Do we need to create a jitter buffer?
        if self.jitterBuffer == nil,
           self.jitterBufferConfig.mode != .layer,
           self.jitterBufferConfig.mode != .none {
            // Create the video jitter buffer.
            try createJitterBuffer(frame: frame)
            assert(self.dequeueTask == nil)
            createDequeueTask()
        }

        // Do we need to copy the frame data?
        let copy = self.jitterBuffer != nil || self.jitterBufferConfig.mode == .layer
        let frame: DecimusVideoFrame = copy ? try .init(copy: frame) : frame

        // Either write the frame to the jitter buffer or otherwise decode it.
        if let jitterBuffer = self.jitterBuffer {
            try jitterBuffer.write(videoFrame: frame, from: from)
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

            if resolvedFps != self.lastFps || first.formatDescription?.dimensions != self.lastDimensions {
                self.lastFps = resolvedFps
                self.lastDimensions = first.formatDescription?.dimensions
                DispatchQueue.main.async {
                    do {
                        guard self.simulreceive != .enable else { return }
                        let participant = self.participants.getOrMake(identifier: try self.fullTrackName.getNamespace())
                        participant.label = .init(describing: self)
                    } catch {
                        Self.logger.error("Failed to set label: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? from : nil
            Task(priority: .utility) {
                if let captureDate = frame.captureDate,
                   let now = now {
                    let age = now.timeIntervalSince(captureDate)
                    await measurement.measurement.age(age: age, timestamp: now)
                }
                await measurement.measurement.receivedFrame(timestamp: now, idr: frame.objectId == 0)
                let bytes = frame.samples.reduce(into: 0) { $0 += $1.totalSampleSize }
                await measurement.measurement.receivedBytes(received: bytes, timestamp: now)
            }
        }
    }

    /// Calculates the time until the next frame would be expected, or nil if there is no next frame.
    /// - Parameter from: The time to calculate from.
    /// - Returns Time to wait in seconds, if any.
    func calculateWaitTime(from: Date) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else {
            fatalError("Shouldn't use calculateWaitTime with no jitterbuffer")
        }
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs > 0 else { fatalError("This must be set prior to dequeueing") }
        let diff = TimeInterval(diffUs) / 1_000_000.0
        return jitterBuffer.calculateWaitTime(from: from, offset: diff)
    }

    func calculateWaitTime(frame: DecimusVideoFrame, from: Date = .now) -> TimeInterval {
        guard let jitterBuffer = self.jitterBuffer else {
            fatalError("Shouldn't use calculateWaitTime with no jitterbuffer")
        }
        let diffUs = self.timestampTimeDiffUs.load(ordering: .acquiring)
        guard diffUs > 0 else { fatalError("This must be set prior to dequeueing") }
        let diff = TimeInterval(diffUs) / 1_000_000.0
        return jitterBuffer.calculateWaitTime(frame: frame, from: from, offset: diff)
    }

    private func createJitterBuffer(frame: DecimusVideoFrame) throws {
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
        self.jitterBuffer = try .init(fullTrackName: self.fullTrackName,
                                      metricsSubmitter: self.metricsSubmitter,
                                      sort: !self.reliable,
                                      minDepth: self.jitterBufferConfig.minDepth,
                                      capacity: Int(floor(self.jitterBufferConfig.capacity / duration)))
        self.duration = duration
    }

    private func createDequeueTask() {
        // Start the frame dequeue task.
        self.dequeueTask = .init(priority: .high) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let now = Date.now

                // Wait until we expect to have a frame available.
                let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                let waitTime: TimeInterval
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
                if waitTime > 0 {
                    do {
                        try await Task.sleep(for: .seconds(waitTime),
                                             tolerance: .seconds(waitTime / 2),
                                             clock: .continuous)
                        guard let task = self.dequeueTask,
                              !task.isCancelled else {
                            return
                        }
                    } catch {
                        Self.logger.error("Exception during sleep: \(error.localizedDescription)")
                        continue
                    }
                }

                // Attempt to dequeue a frame.
                if let sample = jitterBuffer.read(from: now) {
                    if self.granularMetrics,
                       let measurement = self.measurement?.measurement {
                        let time = self.calculateWaitTime(frame: sample)
                        Task(priority: .utility) {
                            await measurement.frameDelay(delay: time, metricsTimestamp: now)
                        }
                    }

                    do {
                        try self.decode(sample: sample, from: now)
                    } catch {
                        Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func setTimeDiff(diff: TimeInterval) {
        assert(diff > (1 / 1_000_000))
        let diffUs = UInt64(diff * 1_000_000)
        _ = self.timestampTimeDiffUs.compareExchange(expected: 0,
                                                     desired: diffUs,
                                                     ordering: .acquiringAndReleasing)
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
                try self.enqueueSample(sample: sampleBuffer,
                                       orientation: sample.orientation,
                                       verticalMirror: sample.verticalMirror,
                                       from: from)
            } else {
                if let orientation = sample.orientation {
                    self.atomicOrientation.store(orientation.rawValue, ordering: .releasing)
                }
                if let verticalMirror = sample.verticalMirror {
                    self.atomicMirror.store(verticalMirror, ordering: .releasing)
                }
                try decoder!.write(sampleBuffer)
            }
        }
    }

    private func enqueueSample(sample: CMSampleBuffer,
                               orientation: DecimusVideoRotation?,
                               verticalMirror: Bool?,
                               from: Date) throws {
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
                let participant = self.participants.getOrMake(identifier: try self.fullTrackName.getNamespace())
                // Set the layer's start time to the first sample's timestamp minus the target depth.
                if !self.startTimeSet {
                    try self.setLayerStartTime(layer: participant.view.layer!, time: sample.presentationTimeStamp)
                    self.startTimeSet = true
                }
                try participant.view.enqueue(sample, transform: orientation?.toTransform(verticalMirror!))
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
        DispatchQueue.main.async {
            do {
                let participant = self.participants.getOrMake(identifier: try self.fullTrackName.getNamespace())
                try participant.view.flush()
            } catch {
                Self.logger.error("Could not flush layer: \(error)")
            }
            Self.logger.debug("Flushing display layer")
            self.startTimeSet = false
        }
    }

    private func labelFromSample(sample: CMSampleBuffer, fps: UInt16) throws -> String {
        guard let format = sample.formatDescription else {
            throw "Missing sample format"
        }
        let size = format.dimensions
        let namespace = self.fullTrackName.namespace
        return "\(namespace): \(String(describing: config.codec)) \(size.width)x\(size.height) \(fps)fps \(Float(config.bitrate) / pow(10, 6))Mbps"
    }
    
    private func depacketize(fullTrackName: FullTrackName,
                             data: Data,
                             groupId: UInt64,
                             objectId: UInt64) throws -> DecimusVideoFrame? {
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
            sei = seis.reduce(ApplicationSEI(timestamp: nil, orientation: nil, age: nil)) { result, next in
                let timestamp = next.timestamp ?? result.timestamp
                let orientation = next.orientation ?? result.orientation
                let age = next.age ?? result.age
                return .init(timestamp: timestamp, orientation: orientation, age: age)
            }
        }

        guard let buffers = buffers else { return nil }
        let timeInfo: CMSampleTimingInfo
        if let timestamp = sei?.timestamp {
            timeInfo = .init(duration: .invalid, presentationTimeStamp: timestamp.timestamp, decodeTimeStamp: .invalid)
        } else {
            Self.logger.error("Missing expected frame timestamp")
            timeInfo = .invalid
        }

        var samples: [CMSampleBuffer] = []
        for buffer in buffers {
            samples.append(try CMSampleBuffer(dataBuffer: buffer,
                                              formatDescription: format,
                                              numSamples: 1,
                                              sampleTimings: [timeInfo],
                                              sampleSizes: [buffer.dataLength]))
        }

        let captureDate: Date?
        if let age = sei?.age {
            captureDate = Date(timeIntervalSinceReferenceDate: age.timestamp.seconds)
        } else {
            captureDate = nil
        }

        return .init(samples: samples,
                     groupId: groupId,
                     objectId: objectId,
                     sequenceNumber: sei?.timestamp?.sequenceNumber,
                     fps: sei?.timestamp?.fps,
                     orientation: sei?.orientation?.orientation,
                     verticalMirror: sei?.orientation?.verticalMirror,
                     captureDate: captureDate)
    }
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

extension CMVideoDimensions: @retroactive Equatable {
    public static func == (lhs: CMVideoDimensions, rhs: CMVideoDimensions) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }
}
