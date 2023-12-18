import AVFoundation

// swiftlint:disable type_body_length

/// Handles decoding, jitter, and rendering of a video stream.
class VideoHandler: CustomStringConvertible {
    private static let logger = DecimusLogger(VideoHandler.self)

    /// The current configuration in use.
    let config: VideoCodecConfig
    /// A description of the video handler.
    var description: String
    /// The namespace identifying this stream.
    let namespace: QuicrNamespace

    private var decoder: VTDecoder?
    private let participants: VideoParticipants
    private let measurement: _Measurement?
    private var lastGroup: UInt32?
    private var lastObject: UInt16?
    private let namegate: NameGate
    private let reliable: Bool
    private var jitterBuffer: VideoJitterBuffer?
    private var lastReceive: Date?
    private var lastDecode: Date?
    private let granularMetrics: Bool
    private var dequeueTask: Task<(), Never>?
    private var dequeueBehaviour: VideoDequeuer?
    private let jitterBufferConfig: VideoJitterBuffer.Config
    private var orientation: AVCaptureVideoOrientation?
    private var verticalMirror: Bool?
    private var currentFormat: CMFormatDescription?
    private var startTimeSet = false
    private let metricsSubmitter: MetricsSubmitter?
    private let simulreceive: SimulreceiveMode
    private var lastDecodedImage: CMSampleBuffer?
    private let lastDecodedImageLock = NSLock()
    private var timestampTimeDiff: TimeInterval?

    /// Create a new video handler.
    /// - Parameters:
    ///     - namespace: The namespace for this video stream.
    ///     - config: Codec configuration for this video stream.
    ///     - participants: Video participants dependency for rendering.
    ///     - metricsSubmitter: If present, a submitter to record metrics through.
    ///     - namegate: Object to make decisions about valid group/object values.
    ///     - reliable: True if this stream should be considered to be reliable (in order, no loss).
    ///     - granularMetrics: True to record per frame / operation metrics at a performance cost.
    ///     - jitterBufferConfig: Requested configuration for jitter handling.
    ///     - simulreceive: The mode to operate in if any sibling streams are present.
    /// - Throws: Simulreceive cannot be used with a jitter buffer mode of `layer`.
    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config,
         simulreceive: SimulreceiveMode) throws {
        if simulreceive != .none && jitterBufferConfig.mode == .layer {
            throw "Simulreceive and layer are not compatible"
        }

        self.namespace = namespace
        self.config = config
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.namegate = namegate
        self.reliable = reliable
        self.granularMetrics = granularMetrics
        self.jitterBufferConfig = jitterBufferConfig
        self.simulreceive = simulreceive
        self.metricsSubmitter = metricsSubmitter
        self.description = self.namespace

        if jitterBufferConfig.mode != .layer {
            // Create the decoder.
            self.decoder = .init(config: self.config) { [weak self] sample in
                guard let self = self else { return }
                if simulreceive != .none {
                    self.lastDecodedImageLock.withLock {
                        self.lastDecodedImage = sample
                    }
                }
                if simulreceive != .enable {
                    // Enqueue for rendering.
                    do {
                        try self.enqueueSample(sample: sample,
                                               orientation: self.orientation,
                                               verticalMirror: self.verticalMirror)
                    } catch {
                        Self.logger.error("Failed to enqueue decoded sample: \(error)")
                    }
                }
            }
        }
    }

    deinit {
        if self.simulreceive != .enable {
            try? participants.removeParticipant(identifier: namespace)
        }
    }

    /// Get the last decoded image, if any.
    /// - Returns Last decoded sample buffer, or nil if none available.
    func getLastImage() -> CMSampleBuffer? {
        self.lastDecodedImageLock.withLock {
            let image = self.lastDecodedImage
            return image
        }
    }

    /// Remove the last image if it matches the provided image. If there is a mismatch, it has already happened.
    /// - Parameter sample The sample we are intending to remove.
    func removeLastImage(sample: CMSampleBuffer) {
        self.lastDecodedImageLock.withLock {
            if sample == self.lastDecodedImage {
                self.lastDecodedImage = nil
            }
        }
    }

    /// Calculate the estimated time interval until the next frame should be rendered from now.
    /// - Returns The time to wait, or nil if no estimation can be made. (There is no next frame, or no start time).
    func calculateWaitTime() -> TimeInterval? {
        calculateWaitTime(from: .now)
    }

    /// Calculate the estimated time interval until the next frame should be rendered.
    /// - Parameter from The time to calculate the time interval from.
    /// - Returns The time to wait, or nil if no estimation can be made. (There is no next frame, or no start time).
    func calculateWaitTime(from: Date) -> TimeInterval? {
        guard let jitterBuffer = self.jitterBuffer else {
            fatalError("Shouldn't call this with no jitter buffer")
        }
        guard let peek = jitterBuffer.peek(),
              let diff = self.timestampTimeDiff else {
            return nil
        }
        let sample = peek as! CMSampleBuffer
        let timestampValue = sample.presentationTimeStamp.seconds
        let targetTimeRef = timestampValue + diff
        let targetDate = Date(timeIntervalSinceReferenceDate: targetTimeRef)
        return targetDate.timeIntervalSinceNow + self.jitterBufferConfig.minDepth
    }

    // swiftlint:disable cyclomatic_complexity
    // swiftlint:disable function_body_length
    /// Pass an encoded video frame to this video handler.
    /// - Parameter data Encoded H264 frame data.
    /// - Parameter groupId The group.
    /// - Parameter objectId The object in the group.
    func submitEncodedData(_ data: Data, groupId: UInt32, objectId: UInt16) throws {
        // Metrics.
        if let measurement = self.measurement {
            let now: Date? = self.granularMetrics ? .now : nil
            let delta: Double?
            if granularMetrics {
                if let last = lastReceive {
                    delta = now!.timeIntervalSince(last) * 1000
                } else {
                    delta = nil
                }
                lastReceive = now
            } else {
                delta = nil
            }

            Task(priority: .utility) {
                if let delta = delta {
                    await measurement.receiveDelta(delta: delta, timestamp: now)
                }
                await measurement.receivedFrame(timestamp: now)
                await measurement.receivedBytes(received: data.count, timestamp: now)
            }
        }

        // If we're not doing full simulreceive, it's our responsibility.
        if simulreceive != .enable {
            // Update keep alive timer for showing video.
            DispatchQueue.main.async {
                let participant = self.participants.getOrMake(identifier: self.namespace)
                participant.lastUpdated = .now()
            }
        }

        // Do we need to create a jitter buffer?
        var samples: [CMSampleBuffer]?
        if self.jitterBuffer == nil,
           self.jitterBufferConfig.mode != .layer,
           self.jitterBufferConfig.mode != .none {
            // Create the video jitter buffer.
            samples = try depacketize(data, groupId: groupId, objectId: objectId, copy: true)
            var remoteFPS = self.config.fps
            if let samples = samples,
               let first = samples.first {
                remoteFPS = getFps(sample: first)
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
            self.jitterBuffer = try .init(namespace: self.namespace,
                                          metricsSubmitter: self.metricsSubmitter,
                                          sort: !self.reliable,
                                          minDepth: self.jitterBufferConfig.minDepth,
                                          capacity: Int(ceil(self.jitterBufferConfig.minDepth / duration) * 10))

            assert(self.dequeueTask == nil)
            // Start the frame dequeue task.
            self.dequeueTask = .init(priority: .high) { [weak self] in
                while !Task.isCancelled {
                    guard let self = self else { return }

                    // Wait until we expect to have a frame available.
                    let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                    let waitTime: TimeInterval
                    if let pid = self.dequeueBehaviour as? PIDDequeuer {
                        pid.currentDepth = jitterBuffer.getDepth()
                        waitTime = self.dequeueBehaviour!.calculateWaitTime()
                    } else {
                        waitTime = calculateWaitTime() ?? duration
                    }
                    if waitTime > 0 {
                        try? await Task.sleep(for: .seconds(waitTime),
                                              tolerance: .seconds(waitTime / 2),
                                              clock: .continuous)
                    }

                    // Attempt to dequeue a frame.
                    if let sample = jitterBuffer.read() {
                        do {
                            try self.decode(sample: sample)
                        } catch {
                            Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }

        // Either write the frame to the jitter buffer or otherwise decode it.
        if let jitterBuffer = self.jitterBuffer {
            if samples == nil {
                samples = try depacketize(data, groupId: groupId, objectId: objectId, copy: true)
            }
            if let samples = samples {
                for sample in samples {
                    do {
                        // Save starting time.
                        if self.timestampTimeDiff == nil {
                            self.timestampTimeDiff = Date.now.timeIntervalSinceReferenceDate - sample.presentationTimeStamp.seconds
                        }
                        try jitterBuffer.write(videoFrame: sample)
                    } catch {
                        Self.logger.warning("Failed to enqueue video frame: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            if let samples = try depacketize(data,
                                             groupId: groupId,
                                             objectId: objectId,
                                             copy: self.jitterBufferConfig.mode == .layer) {
                for sample in samples {
                    try decode(sample: sample)
                }
            }
        }
    }

    private func depacketize(_ data: Data, groupId: UInt32, objectId: UInt16, copy: Bool) throws -> [CMSampleBuffer]? {
        let samples: [CMSampleBuffer]?

        switch self.config.codec {
        case .h264:
            samples = try H264Utilities.depacketize(data,
                                                    groupId: groupId,
                                                    objectId: objectId,
                                                    format: &self.currentFormat,
                                                    orientation: &self.orientation,
                                                    verticalMirror: &self.verticalMirror,
                                                    copy: copy)
        case .hevc:
            samples = try HEVCUtilities.depacketize(data,
                                                    groupId: groupId,
                                                    objectId: objectId,
                                                    format: &self.currentFormat,
                                                    orientation: &self.orientation,
                                                    verticalMirror: &self.verticalMirror,
                                                    copy: copy)
        default:
            throw "Unsupported codec: \(self.config.codec)"
        }

        if let first = samples?.first {
            do {
                let label = try self.labelFromSample(sample: first, fps: self.getFps(sample: first))
                DispatchQueue.main.async {
                    self.description = label
                }
            } catch {
                Self.logger.error("Failed to set label: \(error.localizedDescription)")
            }
        }
        return samples
    }

    private func decode(sample: CMSampleBuffer) throws {
        // Should we feed this frame to the decoder?
        // get groupId and objectId from the frame (1st frame)
        guard let groupId = sample.getGroupId(),
              let objectId = sample.getObjectId() else {
            throw "Missing attachments"
        }
        guard namegate.handle(groupId: groupId,
                              objectId: objectId,
                              lastGroup: lastGroup,
                              lastObject: lastObject) else {
            // If we've thrown away a frame, we should flush to the next group.
            let targetGroup = groupId + 1
            if let jitterBuffer = self.jitterBuffer {
                jitterBuffer.flushTo(targetGroup: targetGroup)
            } else if self.jitterBufferConfig.mode == .layer {
                flushDisplayLayer()
            }
            return
        }

        lastGroup = groupId
        lastObject = objectId

        // Remove custom attachments.
        sample.clearDecimusCustomAttachments()

        // Decode.
        if self.jitterBufferConfig.mode == .layer {
            try self.enqueueSample(sample: sample, orientation: self.orientation, verticalMirror: self.verticalMirror)
        } else {
            try decoder!.write(sample)
        }
    }

    private func enqueueSample(sample: CMSampleBuffer,
                               orientation: AVCaptureVideoOrientation?,
                               verticalMirror: Bool?) throws {
        if let measurement = self.measurement,
           self.jitterBufferConfig.mode != .layer {
            let now: Date? = self.granularMetrics ? .now : nil
            let delta: Double?
            if self.granularMetrics {
                if let last = lastDecode {
                    delta = now!.timeIntervalSince(last) * 1000
                } else {
                    delta = nil
                }
                lastDecode = now
            } else {
                delta = nil
            }
            Task(priority: .utility) {
                if let delta = delta {
                    await measurement.decodeDelta(delta: delta, timestamp: now)
                }
                await measurement.decodedFrame(timestamp: now)
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
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                // Set the layer's start time to the first sample's timestamp minus the target depth.
                if !self.startTimeSet {
                    try self.setLayerStartTime(layer: participant.view.layer!, time: sample.presentationTimeStamp)
                    self.startTimeSet = true
                }
                try participant.view.enqueue(sample, transform: orientation?.toTransform(verticalMirror!))
                participant.view.label = self.description
            } catch {
                Self.logger.error("Could not enqueue sample: \(error)")
            }
            participant.lastUpdated = .now()
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
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                try participant.view.flush()
            } catch {
                Self.logger.error("Could not flush layer: \(error)")
            }
            Self.logger.debug("Flushing display layer")
            self.startTimeSet = false
        }
    }

    private func getFps(sample: CMSampleBuffer) -> UInt16 {
        var remoteFPS = self.config.fps
        if let fps = sample.getFPS() {
            remoteFPS = UInt16(fps)
        }
        return remoteFPS
    }

    private func labelFromSample(sample: CMSampleBuffer, fps: UInt16) throws -> String {
        guard let format = sample.formatDescription else {
            throw "Missing sample format"
        }
        let size = format.dimensions
        return "\(self.namespace): \(String(describing: config.codec)) \(size.width)x\(size.height) \(fps)fps \(Float(config.bitrate) / pow(10, 6))Mbps"
    }
}

extension AVCaptureVideoOrientation {
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
        default:
            break
        }
        return transform
    }
}

extension VideoHandler: Hashable {
    static func == (lhs: VideoHandler, rhs: VideoHandler) -> Bool {
        return lhs.namespace == rhs.namespace
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.namespace)
    }
}
