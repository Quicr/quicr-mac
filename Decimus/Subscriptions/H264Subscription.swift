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
    private let jitterFrameDepth: UInt64
    private var currentJitterFramesCount: UInt64

    private var decoder: H264Decoder?
    private unowned let participants: VideoParticipants
    private let measurement: _Measurement?
    private var lastGroup: UInt32?
    private var lastObject: UInt16?
    private let namegate: NameGate
    private let reliable: Bool
    private var jitterBuffer: VideoJitterBuffer?
    private var decodeTimer: Timer?

    private lazy var decodeBlock: (Timer) -> Void = { [weak self] _ in
        DispatchQueue.global(qos: .userInteractive).async {
            self?.dequeue()
        }
    }
    private var lastReceive: Date?
    private var lastDecode: Date?
    private let granularMetrics: Bool

    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool,
         minDepth: TimeInterval,
         granularMetrics: Bool,
         useJitterBuffer: Bool) {
        self.namespace = namespace
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.namegate = namegate
        self.reliable = reliable
        self.granularMetrics = granularMetrics

        self.jitterFrameDepth = UInt64(ceil(minDepth * Float64(config.fps)))
        self.currentJitterFramesCount = self.jitterFrameDepth

        if useJitterBuffer {
            self.jitterBuffer = .init(namespace: namespace,
                                      frameDuration: 1 / Double(config.fps),
                                      minDepth: minDepth,
                                      metricsSubmitter: metricsSubmitter,
                                      sort: !reliable)
            // Decode job: timer procs on main thread, but decoding itself doesn't.
            DispatchQueue.main.async {
                self.decodeTimer = .scheduledTimer(withTimeInterval: 1 / Double(config.fps),
                                                   repeats: true,
                                                   block: self.decodeBlock)
                self.decodeTimer!.tolerance = 1 / Double(config.fps) / 4
            }
        }
        self.decoder = .init(config: config, callback: { [weak self] sample, orientation, mirror in
            self?.enqueueModifiedSamples(samples: sample,
                                   timestamp: sample.presentationTimeStamp.value,
                                   orientation: orientation,
                                   verticalMirror: mirror)
        })

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
        }

        if let jitterBuffer = self.jitterBuffer {
            let videoFrame: VideoFrame = .init(groupId: groupId, objectId: objectId, data: .init(bytes: data, count: length))
            _ = jitterBuffer.write(videoFrame: videoFrame)
        } else {
            let zeroCopy: Data = .init(bytesNoCopy: .init(mutating: data), count: length, deallocator: .none)
            let videoFrame: VideoFrame = .init(groupId: groupId, objectId: objectId, data: zeroCopy)
            decode(frame: videoFrame)
        }
        return SubscriptionError.None.rawValue
    }

    private func dequeue() {
        // Try and dequeue a video frame.
        guard let dequeuedFrame = self.jitterBuffer!.read() else { return }
        decode(frame: dequeuedFrame)
    }

    private func decode(frame: VideoFrame) {
        // Should we feed this frame to the decoder?
        guard namegate.handle(groupId: frame.groupId,
                              objectId: frame.objectId,
                              lastGroup: lastGroup,
                              lastObject: lastObject) else {
            // If we've thrown away a frame, we should flush to the next group.
            let targetGroup = frame.groupId + 1
            self.jitterBuffer?.flushTo(targetGroup: targetGroup)

            flushDisplayLayer()

            return
        }

        lastGroup = frame.groupId
        lastObject = frame.objectId

        // Decode.
        do {
            try frame.data.withUnsafeBytes {
                try decoder!.write(data: $0, timestamp: currentJitterFramesCount)
            }
        } catch {
            Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
        }

        currentJitterFramesCount += 1
    }

    private func enqueueModifiedSamples(samples: CMSampleBuffer,
                                        timestamp: CMTimeValue,
                                        orientation: AVCaptureVideoOrientation?,
                                        verticalMirror: Bool) {
        if let measurement = self.measurement {
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

        // Enqueue the buffer.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                try participant.view.enqueue(samples, transform: orientation?.toTransform(verticalMirror))
            } catch {
                Self.logger.error("Could not enqueue decoded sample: \(error)")
            }
            participant.lastUpdated = .now()
        }
    }

    private func flushDisplayLayer() {
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            do {
                try participant.view.flush()
            } catch {
                Self.logger.error("Could not flush layer: \(error)")
            }

            self.currentJitterFramesCount = self.jitterFrameDepth
            Self.logger.debug("Flushing display layer")
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
