import AVFoundation
import os

class H264Subscription: Subscription {
    private static let logger = DecimusLogger(H264Subscription.self)

    private actor _Measurement: Measurement {
        var name: String = "H264Subscription"
        var fields: [Date?: [String: AnyObject]] = [:]
        var tags: [String: String] = [:]

        private var frames: UInt64 = 0
        private var bytes: UInt64 = 0
        private var decoded: UInt64 = 0

        init(namespace: QuicrNamespace, submitter: MetricsSubmitter) {
            tags["namespace"] = namespace
            Task(priority: .utility) {
                await submitter.register(measurement: self)
            }
        }

        func receivedFrame(timestamp: Date?) {
            self.frames += 1
            record(field: "receivedFrames", value: self.frames as AnyObject, timestamp: timestamp)
        }

        func decodedFrame(timestamp: Date?) {
            self.decoded += 1
            record(field: "decodedFrames", value: self.decoded as AnyObject, timestamp: timestamp)
        }

        func receivedBytes(received: Int, timestamp: Date?) {
            self.bytes += UInt64(received)
            record(field: "receivedBytes", value: self.bytes as AnyObject, timestamp: timestamp)
        }

        func receiveDelta(delta: Double, timestamp: Date?) {
            record(field: "receiveDelta", value: delta as AnyObject, timestamp: timestamp)
        }

        func decodeDelta(delta: Double, timestamp: Date?) {
            record(field: "decodeDelta", value: delta as AnyObject, timestamp: timestamp)
        }
    }

    internal let namespace: QuicrNamespace

    private var decoder: H264Decoder?
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
    private let config: VideoCodecConfig
    private var orientation: AVCaptureVideoOrientation?
    private var verticalMirror: Bool?
    private var currentFormat: CMFormatDescription?
    private var startTimeSet = false
    private var label: String = ""

    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         granularMetrics: Bool,
         jitterBufferConfig: VideoJitterBuffer.Config) {
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

        if jitterBufferConfig.mode != .layer {
            // Create the decoder.
            self.decoder = .init(config: config) { [weak self] sample in
                guard let self = self else { return }
                do {
                    try self.enqueueSample(sample: sample, orientation: self.orientation, verticalMirror: self.verticalMirror)
                } catch {
                    Self.logger.error("Failed to enqueue decoded sample: \(error)")
                }
            }

            // We have what we need to configure the PID dequeuer if using.
            let duration = 1 / Double(config.fps)
            if jitterBufferConfig.mode == .pid {
                self.dequeueBehaviour = PIDDequeuer(targetDepth: jitterBufferConfig.minDepth,
                                                    frameDuration: duration,
                                                    kp: 0.01,
                                                    ki: 0.001,
                                                    kd: 0.001)
            }

            // Create the video jitter buffer.
            if jitterBufferConfig.mode != .none {
                self.jitterBuffer = .init(namespace: namespace,
                                          frameDuration: duration,
                                          metricsSubmitter: metricsSubmitter,
                                          sort: !reliable,
                                          minDepth: jitterBufferConfig.minDepth)
            }
        }

        Self.logger.info("Subscribed to H264 stream")
    }

    deinit {
        try? participants.removeParticipant(identifier: namespace)
    }

    func prepare(_ sourceID: SourceIDType!,
                 label: String!,
                 qualityProfile: String!,
                 reliable: UnsafeMutablePointer<Bool>!) -> Int32 {
        reliable.pointee = self.reliable
        self.label = "\(label!): \(String(describing: config.codec)) \(config.width)x\(config.height) \(config.fps)fps \(Float(config.bitrate) / pow(10, 6))Mbps"

        return SubscriptionError.None.rawValue
    }

    func update(_ sourceId: String!, label: String!, qualityProfile: String!) -> Int32 {
        return SubscriptionError.NoDecoder.rawValue
    }

    func subscribedObject(_ data: UnsafeRawPointer!, length: Int, groupId: UInt32, objectId: UInt16) -> Int32 {
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
                await measurement.receivedBytes(received: length, timestamp: now)
            }
        }

        // Update keep alive timer for showing video.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            participant.lastUpdated = .now()
            participant.view.label = self.label
        }

        if let jitterBuffer = self.jitterBuffer {
            let samples: [CMSampleBuffer]?
            do {
                // TODO: No copy?
                samples = try H264Utilities.depacketize(.init(bytes: data, count: length),
                                                        groupId: groupId,
                                                        objectId: objectId,
                                                        format: &self.currentFormat,
                                                        orientation: &self.orientation,
                                                        verticalMirror: &self.verticalMirror)
            } catch {
                Self.logger.error("Failed to depacketize")
                return 0
            }
            
            var remoteFPS = self.config.fps
            if let samples = samples {
                _ = jitterBuffer.write(videoFrame: .init(samples: samples))
                remoteFPS = UInt16(samples[0].getFPS())
            }
        
            if self.dequeueTask == nil {
                // We know everything to create the interval dequeuer at this point.
                if self.dequeueBehaviour == nil && self.jitterBufferConfig.mode == .interval {
                    self.dequeueBehaviour = IntervalDequeuer(minDepth: self.jitterBufferConfig.minDepth,
                                                             frameDuration: 1 / Double(remoteFPS),
                                                             firstWriteTime: .now)
                }

                // Start the frame dequeue task.
                self.dequeueTask = .init(priority: .high) { [weak self] in
                    while !Task.isCancelled {
                        guard let self = self else { return }

                        // Wait until we expect to have a frame available.
                        let jitterBuffer = self.jitterBuffer! // Jitter buffer must exist at this point.
                        let waitTime: TimeInterval
                        if let pid = self.dequeueBehaviour! as? PIDDequeuer {
                            pid.currentDepth = jitterBuffer.getDepth()
                            waitTime = self.dequeueBehaviour!.calculateWaitTime()
                        } else {
                            waitTime = jitterBuffer.calculateWaitTime()
                        }
                        let nanoseconds = waitTime * 1_000_000_000
                        if nanoseconds > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(nanoseconds))
                        }

                        // Attempt to dequeue a frame.
                        if let frame = jitterBuffer.read() {
                            // Interval dequeuer needs to know where we are.
                            // TODO: With frame timestamps, we won't need this.
                            if self.jitterBufferConfig.mode == .interval {
                                guard let interval = self.dequeueBehaviour as? IntervalDequeuer else {
                                    fatalError("Mode/type mismatch")
                                }
                                interval.dequeuedCount += 1
                            }
                            self.decode(frame: frame)
                        }
                    }
                }
            }
        } else {
            let samples: [CMSampleBuffer]?
            do {
                samples = try H264Utilities.depacketize(.init(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none), groupId: groupId, objectId: objectId, format: &self.currentFormat, orientation: &self.orientation, verticalMirror: &self.verticalMirror)
            } catch {
                Self.logger.error("Failed to depacketize")
                return 0
            }
            
            if let samples = samples {
                decode(frame: .init(samples: samples))
            }
        }
        return SubscriptionError.None.rawValue
    }

    private func decode(frame: VideoFrame) {
        // Should we feed this frame to the decoder?
        // get groupId and objectId from the frame (1st frame)
        let groupId = frame.getGroupId()
        let objectId = frame.getObjectId()

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

        // Decode.
        do {
            for sample in frame.samples {
                if self.jitterBufferConfig.mode == .layer {
                    try self.enqueueSample(sample: sample, orientation: self.orientation, verticalMirror: self.verticalMirror)
                } else {
                    try decoder!.write(sample)
                }
            }
        } catch {
            Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
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

        let sampleToEnqueue: CMSampleBuffer
        if self.jitterBufferConfig.mode == .layer {
            // Deep copy the sample.
            let copied = malloc(sample.dataBuffer!.dataLength)
            try sample.dataBuffer!.withUnsafeMutableBytes {
                _ = memcpy(copied, $0.baseAddress, $0.count)
            }
            let blockBuffer = try CMBlockBuffer(buffer: .init(start: copied,
                                                              count: sample.dataBuffer!.dataLength)) { ptr, _ in
                free(ptr)
            }
            sampleToEnqueue = try! CMSampleBuffer(dataBuffer: blockBuffer,
                                                  formatDescription: sample.formatDescription,
                                                  numSamples: sample.numSamples,
                                                  sampleTimings: sample.sampleTimingInfos(),
                                                  sampleSizes: sample.sampleSizes())
        } else {
            // We're taking care of time already, show immediately.
            if sample.sampleAttachments.count > 0 {
                sample.sampleAttachments[0][.displayImmediately] = true
            } else {
                Self.logger.warning("Couldn't set display immediately attachment")
            }
            sampleToEnqueue = sample
        }

        // Enqueue the sample on the main thread.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                // Set the layer's start time to the first sample's timestamp minus the target depth.
                if !self.startTimeSet {
                    try self.setLayerStartTime(layer: participant.view.layer!, time: sampleToEnqueue.presentationTimeStamp)
                    self.startTimeSet = true
                }
                try participant.view.enqueue(sampleToEnqueue, transform: orientation?.toTransform(verticalMirror!))
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
