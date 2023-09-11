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
            self.frames += 1
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
    private unowned let participants: VideoParticipants
    private let measurement: _Measurement?
    private var lastGroup: UInt32?
    private var lastObject: UInt16?
    private let namegate: NameGate
    private let reliable: Bool
    private var lastReceive: Date?
    private var lastDecode: Date?

    init(namespace: QuicrNamespace,
         config: VideoCodecConfig,
         participants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         namegate: NameGate,
         reliable: Bool) {
        self.namespace = namespace
        self.participants = participants
        if let metricsSubmitter = metricsSubmitter {
            self.measurement = .init(namespace: namespace, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.namegate = namegate
        self.reliable = reliable
        self.decoder = .init(config: config, callback: { [weak self] sample, orientation, mirror in
            self?.showDecodedImage(decoded: sample,
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

    func subscribedObject(_ data: Data!, groupId: UInt32, objectId: UInt16) -> Int32 {
        // Metrics.
        if let measurement = self.measurement {
            let now: Date = .now
            let delta: Double?
            if let last = lastReceive {
                delta = now.timeIntervalSince(last) * 1000
            } else {
                delta = nil
            }
            lastReceive = now
            Task(priority: .utility) {
                if let delta = delta {
                    await measurement.receiveDelta(delta: delta, timestamp: now)
                }
                await measurement.receivedFrame(timestamp: now)
                await measurement.receivedBytes(received: data.count, timestamp: now)
            }
        }

        // Update keep alive timer for showing video.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            participant.lastUpdated = .now()
        }

        // Should we feed this frame to the decoder?
        guard namegate.handle(groupId: groupId, objectId: objectId, lastGroup: lastGroup, lastObject: lastObject) else {
            var group: String = "None"
            if let lastGroup = lastGroup {
                group = String(lastGroup)
            }
            var object: String = "None"
            if let lastObject = lastObject {
                object = String(lastObject)
            }
            Self.logger.warning("[\(groupId)] (\(objectId)) Ignoring blocked object. Had: [\(group)] (\(object))")
            return SubscriptionError.None.rawValue
        }
        lastGroup = groupId
        lastObject = objectId

        // Decode.
        do {
            try data.withUnsafeBytes {
                try decoder!.write(data: $0, timestamp: 0)
            }
        } catch {
            Self.logger.error("Failed to write to decoder: \(error.localizedDescription)")
        }
        return SubscriptionError.None.rawValue
    }

    private func showDecodedImage(decoded: CMSampleBuffer,
                                  timestamp: CMTimeValue,
                                  orientation: AVCaptureVideoOrientation?,
                                  verticalMirror: Bool) {
        if let measurement = self.measurement {
            let now: Date = .now
            let delta: Double?
            if let last = lastDecode {
                delta = now.timeIntervalSince(last) * 1000
            } else {
                delta = nil
            }
            lastDecode = now
            Task(priority: .utility) {
                if let delta = delta {
                    await measurement.decodeDelta(delta: delta, timestamp: now)
                }
                await measurement.decodedFrame(timestamp: now)
            }
        }

        // FIXME: Driving from proper timestamps probably preferable.
        let array: CFArray! = CMSampleBufferGetSampleAttachmentsArray(decoded, createIfNecessary: true)
        let dictionary: CFMutableDictionary = unsafeBitCast(CFArrayGetValueAtIndex(array, 0),
                                                            to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary,
                             Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())

        // Enqueue the buffer.
        DispatchQueue.main.async {
            let participant = self.participants.getOrMake(identifier: self.namespace)
            guard let layer = participant.view.layer else {
                fatalError()
            }
            guard layer.status != .failed else {
                Self.logger.error("Layer failed: \(layer.error!)")
                layer.flush()
                return
            }
            layer.transform = orientation?.toTransform(verticalMirror) ?? CATransform3DIdentity
            layer.enqueue(decoded)
            participant.lastUpdated = .now()
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
