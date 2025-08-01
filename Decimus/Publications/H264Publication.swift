// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFoundation
import Synchronization

enum H264PublicationError: LocalizedError {
    case noCamera(SourceIDType)

    public var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera available"
        }
    }
}

class H264Publication: Publication, FrameListener {
    private let logger = DecimusLogger(H264Publication.self)

    private let measurement: MeasurementRegistration<VideoPublicationMeasurement>?

    let device: AVCaptureDevice
    let queue: DispatchQueue

    private var encoder: VideoEncoder
    private let reliable: Bool
    private let granularMetrics: Bool
    let codec: VideoCodecConfig?
    private var frameRate: Float64?
    private var startTime: Date?
    private var currentGroupId: UInt64?
    private var currentObjectId: UInt64 = 0
    private let generateKeyFrame = Atomic(false)
    private let stagger: Bool
    private let publishFailure = Atomic(false)
    private let verbose: Bool
    private let keyFrameOnUpdate: Bool
    private let sframeContext: SendSFrameContext?

    // Encoded frames arrive in this callback.
    private let onEncodedData: VTEncoder.EncodedCallback = { presentationDate, data, flag, sequence, userData in
        guard let userData = userData else {
            assert(false)
            return
        }
        let publication = Unmanaged<H264Publication>.fromOpaque(userData).takeUnretainedValue()

        // Determine group and object IDs.
        let thisGroupId: UInt64
        let thisObjectId: UInt64
        if let currentGroupId = publication.currentGroupId {
            if flag {
                // Start new group on key frame.
                thisGroupId = currentGroupId + 1
                thisObjectId = 0
            } else {
                // Increment object ID in current GOP.
                thisGroupId = currentGroupId
                thisObjectId = publication.currentObjectId + 1
            }
        } else {
            // Start initial group ID using current time.
            assert(flag)
            thisGroupId = UInt64(Date.now.timeIntervalSince1970)
            thisObjectId = 0
        }

        // Use extensions for LOC.
        let loc = LowOverheadContainer(timestamp: presentationDate, sequence: sequence)
        let now = UInt64(Date.now.timeIntervalSince1970 * 1000)
        loc.add(key: .publishTimestamp, value: withUnsafeBytes(of: now) { Data($0) })

        // Publish.
        let data = Data(bytesNoCopy: .init(mutating: data.baseAddress!),
                        count: data.count,
                        deallocator: .none)
        let protected: Data
        if let sframeContext = publication.sframeContext {
            do {
                protected = try sframeContext.context.mutex.withLock { context in
                    try context.protect(epochId: sframeContext.currentEpoch,
                                        senderId: sframeContext.senderId,
                                        plaintext: data)
                }
            } catch {
                publication.logger.error("Failed to protect data: \(error.localizedDescription)")
                return
            }
        } else {
            protected = data
        }
        var priority = publication.getPriority(flag ? 0 : 1)
        var ttl = publication.getTTL(flag ? 0 : 1)
        let status = publication.publish(groupId: thisGroupId,
                                         objectId: thisObjectId,
                                         data: protected,
                                         priority: &priority,
                                         ttl: &ttl,
                                         extensions: loc.extensions)
        switch status {
        case .ok:
            if publication.verbose {
                publication.logger.debug("Published: \(thisGroupId): \(thisObjectId)")
            }
            publication.publishFailure.store(false, ordering: .releasing)
        default:
            publication.logger.warning("Failed to publish object: \(status)")
            publication.publishFailure.store(true, ordering: .releasing)
            return
        }

        // Update IDs on success.
        publication.currentGroupId = thisGroupId
        publication.currentObjectId = thisObjectId

        // Metrics.
        guard let measurement = publication.measurement else { return }
        let bytes = protected.count
        let sent: Date? = publication.granularMetrics ? Date.now : nil
        Task(priority: .utility) {
            await measurement.measurement.sentFrame(bytes: UInt64(bytes),
                                                    timestamp: presentationDate.timeIntervalSince1970,
                                                    age: sent?.timeIntervalSince(presentationDate) ?? nil,
                                                    metricsTimestamp: sent)
        }
    }

    required init(profile: Profile,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: VideoEncoder,
                  device: AVCaptureDevice,
                  endpointId: String,
                  relayId: String,
                  stagger: Bool,
                  verbose: Bool,
                  keyFrameOnUpdate: Bool,
                  sframeContext: SendSFrameContext?) throws {
        let namespace = profile.namespace.joined()
        self.granularMetrics = granularMetrics
        self.codec = config
        if let metricsSubmitter = metricsSubmitter {
            let measurement = H264Publication.VideoPublicationMeasurement(namespace: namespace)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.queue = .init(label: "com.cisco.quicr.decimus.\(namespace)",
                           target: .global(qos: .userInteractive))
        self.reliable = reliable
        self.encoder = encoder
        self.device = device
        self.stagger = stagger
        self.verbose = verbose
        self.keyFrameOnUpdate = keyFrameOnUpdate
        self.sframeContext = sframeContext
        self.logger.info("Registered H264 publication for namespace \(namespace)")

        guard let defaultPriority = profile.priorities?.first,
              let defaultTTL = profile.expiry?.first else {
            throw "Missing expected profile values"
        }

        try super.init(profile: profile,
                       trackMode: reliable ? .stream : .datagram,
                       defaultPriority: UInt8(clamping: defaultPriority),
                       defaultTTL: UInt16(clamping: defaultTTL),
                       submitter: metricsSubmitter,
                       endpointId: endpointId,
                       relayId: relayId,
                       logger: self.logger)
        let userData = Unmanaged.passUnretained(self).toOpaque()
        self.encoder.setCallback(onEncodedData, userData: userData)
    }

    internal func publish(groupId: UInt64,
                          objectId: UInt64,
                          data: Data,
                          priority: UnsafePointer<UInt8>?,
                          ttl: UnsafePointer<UInt16>?,
                          extensions: [NSNumber: Data]) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: groupId,
                                     objectId: objectId,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: extensions)
    }

    deinit {
        self.logger.debug("Deinit")
    }

    override func statusChanged(_ status: QPublishTrackHandlerStatus) {
        super.statusChanged(status)
        if (status == .subscriptionUpdated && self.keyFrameOnUpdate) || status == .newGroupRequested {
            self.generateKeyFrame.store(true, ordering: .releasing)
        }
    }

    /// This callback fires when a video frame arrives.
    func onFrame(_ sampleBuffer: CMSampleBuffer,
                 timestamp: Date) {
        // Configure FPS.
        let maxRate = self.device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate
        if self.encoder.frameRate == nil {
            self.encoder.frameRate = maxRate
        } else {
            if self.encoder.frameRate != maxRate {
                self.logger.warning("Frame rate mismatch? Had: \(String(describing: self.encoder.frameRate)), got: \(String(describing: maxRate))")
            }
        }

        // If we're not in a state to be publishing, don't go any further.
        guard self.shouldPublish() else {
            self.logger.debug("Didn't encode due to publication status: \(self.getStatus())")
            return
        }

        // Stagger the publication's start time by its height in ms.
        if self.stagger {
            guard let startTime = self.startTime else {
                self.startTime = timestamp
                return
            }
            let interval = timestamp.timeIntervalSince(startTime)
            guard interval > TimeInterval(self.codec!.height) / 1000.0 else {
                self.logger.debug("Dropping due to stagger")
                return
            }
        }

        // Should we be forcing a key frame?
        var keyFrame: Bool {
            // If the last publish failed, we need a key frame.
            guard !self.publishFailure.load(ordering: .acquiring) else {
                self.logger.debug("Forcing key frame - last time didn't publish")
                // Consume any existing request.
                _ = self.generateKeyFrame.compareExchange(expected: true,
                                                          desired: false,
                                                          ordering: .acquiringAndReleasing)
                return true
            }

            // If we asked for key frame, make one (subscribe update).
            let (generate, _) = self.generateKeyFrame.compareExchange(expected: true,
                                                                      desired: false,
                                                                      ordering: .acquiringAndReleasing)
            if generate {
                self.logger.debug("Forcing key frame - subscribe update")
            }
            return generate
        }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer, timestamp: timestamp, forceKeyFrame: keyFrame)
        } catch {
            self.logger.error("Failed to encode frame: \(error.localizedDescription)")
        }

        // Metrics.
        guard let measurement = self.measurement else { return }
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let pixels: UInt64 = .init(width * height)
        let date: Date? = self.granularMetrics ? timestamp : nil
        let now = Date.now
        Task(priority: .utility) {
            await measurement.measurement.sentPixels(sent: pixels, timestamp: date)
            if let date = date {
                // TODO: This age is probably useless.
                let age = now.timeIntervalSince(timestamp)
                await measurement.measurement.age(age: age,
                                                  presentationTimestamp: timestamp.timeIntervalSince1970,
                                                  metricsTimestamp: date)
            }
        }
    }
}
