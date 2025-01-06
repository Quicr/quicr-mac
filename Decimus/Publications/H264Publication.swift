// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Atomics
import Foundation
import AVFoundation

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
    private static let logger = DecimusLogger(H264Publication.self)

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
    private let generateKeyFrame = ManagedAtomic(false)
    private let stagger: Bool

    required init(profile: Profile,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: VideoEncoder,
                  device: AVCaptureDevice,
                  endpointId: String,
                  relayId: String,
                  stagger: Bool) throws {
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

        let onEncodedData: VTEncoder.EncodedCallback = { presentationDate, data, flag, sequence, userData in
            guard let userData = userData else {
                Self.logger.error("UserData unexpectedly was nil")
                return
            }
            let publication = Unmanaged<H264Publication>.fromOpaque(userData).takeUnretainedValue()

            // Encode age.
            let now = publication.measurement != nil && granularMetrics ? Date.now : nil
            if granularMetrics,
               let measurement = publication.measurement {
                let age = now!.timeIntervalSince(presentationDate)
                Task(priority: .utility) {
                    await measurement.measurement.encoded(age: age, timestamp: now!)
                }
            }

            if publication.currentGroupId == nil {
                publication.currentGroupId = UInt64(Date.now.timeIntervalSince1970)
            }

            if flag {
                publication.currentGroupId! += 1
                publication.currentObjectId = 0
            } else {
                publication.currentObjectId += 1
            }

            // Use extensions for LOC.
            let loc = LowOverheadContainer(timestamp: presentationDate, sequence: sequence)

            // Publish.
            let data = Data(bytesNoCopy: .init(mutating: data.baseAddress!),
                            count: data.count,
                            deallocator: .none)
            var priority = publication.getPriority(flag ? 0 : 1)
            var ttl = publication.getTTL(flag ? 0 : 1)
            guard publication.publish.load(ordering: .acquiring) else {
                Self.logger.warning("Didn't publish due to status: \(publication.currentStatus)")
                return
            }
            let status = publication.publish(groupId: publication.currentGroupId!,
                                             objectId: publication.currentObjectId,
                                             data: data,
                                             priority: &priority,
                                             ttl: &ttl,
                                             extensions: loc.extensions)
            switch status {
            case .ok:
                break
            default:
                Self.logger.warning("Failed to publish object: \(status)")
            }

            // Metrics.
            guard let measurement = publication.measurement else { return }
            let bytes = data.count
            let sent: Date? = granularMetrics ? Date.now : nil
            Task(priority: .utility) {
                let age: TimeInterval?
                if let sent = sent {
                    age = sent.timeIntervalSince(presentationDate)
                } else {
                    age = nil
                }
                await measurement.measurement.sentFrame(bytes: UInt64(bytes),
                                                        timestamp: presentationDate.timeIntervalSince1970,
                                                        age: age,
                                                        metricsTimestamp: sent)
            }
        }
        Self.logger.info("Registered H264 publication for namespace \(namespace)")

        guard let defaultPriority = profile.priorities?.first,
              let defaultTTL = profile.expiry?.first else {
            throw "Missing expected profile values"
        }

        try super.init(profile: profile,
                       trackMode: reliable ? .streamPerGroup : .datagram,
                       defaultPriority: UInt8(clamping: defaultPriority),
                       defaultTTL: UInt16(clamping: defaultTTL),
                       submitter: metricsSubmitter,
                       endpointId: endpointId,
                       relayId: relayId)
        let userData = Unmanaged.passUnretained(self).toOpaque()
        self.encoder.setCallback(onEncodedData, userData: userData)
    }

    private func publish(groupId: UInt64, objectId: UInt64, data: Data, priority: UnsafePointer<UInt8>?, ttl: UnsafePointer<UInt16>?, extensions: [NSNumber: Data]) -> QPublishObjectStatus {
        let headers = QObjectHeaders(groupId: groupId,
                                     objectId: objectId,
                                     payloadLength: UInt64(data.count),
                                     priority: priority,
                                     ttl: ttl)
        return self.publishObject(headers, data: data, extensions: extensions)
    }

    deinit {
        Self.logger.debug("Deinit")
    }

    override func statusChanged(_ status: QPublishTrackHandlerStatus) {
        super.statusChanged(status)
        if status == .subscriptionUpdated {
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
                Self.logger.warning("Frame rate mismatch? Had: \(String(describing: self.encoder.frameRate)), got: \(String(describing: maxRate))")
            }
        }

        // Stagger the publication's start time by its height in ms.
        if self.stagger {
            guard let startTime = self.startTime else {
                self.startTime = timestamp
                return
            }
            let interval = timestamp.timeIntervalSince(startTime)
            guard interval > TimeInterval(self.codec!.height) / 1000.0 else { return }
        }

        // Should we be forcing a key frame?
        let (keyFrame, _) = self.generateKeyFrame.compareExchange(expected: true,
                                                                  desired: false,
                                                                  ordering: .acquiringAndReleasing)
        if keyFrame {
            Self.logger.debug("Forcing key frame")
        }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer, timestamp: timestamp, forceKeyFrame: keyFrame)
        } catch {
            Self.logger.error("Failed to encode frame: \(error.localizedDescription)")
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
