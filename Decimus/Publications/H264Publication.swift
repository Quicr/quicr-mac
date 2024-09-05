// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import AVFoundation
import os

enum H264PublicationError: LocalizedError {
    case noCamera(SourceIDType)

    public var errorDescription: String? {
        switch self {
        case .noCamera:
            return "No camera available"
        }
    }
}

class H264Publication: QPublishTrackHandlerObjC, QPublishTrackHandlerCallbacks, FrameListener {
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
    private var currentGroupId: UInt64 = 0
    private var currentObjectId: UInt64 = 0
    private let profile: Profile

    required init(profile: Profile,
                  config: VideoCodecConfig,
                  metricsSubmitter: MetricsSubmitter?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: VideoEncoder,
                  device: AVCaptureDevice) throws {
        self.profile = profile
        let namespace = profile.namespace
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

            if flag {
                publication.currentGroupId += 1
                publication.currentObjectId = 0
            } else {
                publication.currentObjectId += 1
            }

            // Object headers.
            let headers = QObjectHeaders(groupId: publication.currentGroupId,
                                         objectId: publication.currentObjectId,
                                         payloadLength: UInt64(data.count),
                                         priority: nil,
                                         ttl: nil)

            // Use extensions for LOC.
            let loc = LowOverheadContainer(timestamp: presentationDate, sequence: sequence)

            // Publish.
            let data = Data(bytesNoCopy: .init(mutating: data.baseAddress!),
                            count: data.count,
                            deallocator: .none)
            let status = publication.publishObject(headers,
                                                   data: data,
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
        let fullTrackName = try FullTrackName(namespace: profile.namespace, name: "")
        super.init(fullTrackName: fullTrackName.getUnsafe(),
                   trackMode: reliable ? .streamPerGroup : .datagram,
                   defaultPriority: 0,
                   defaultTTL: 0)
        let userData = Unmanaged.passUnretained(self).toOpaque()
        self.encoder.setCallback(onEncodedData, userData: userData)
        self.setCallbacks(self)
    }

    deinit {
        Self.logger.debug("deinit")
    }

    func statusChanged(_ status: QPublishTrackHandlerStatus) {
        Self.logger.info("Status changed: \(status)")
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
        guard let startTime = self.startTime else {
            self.startTime = timestamp
            return
        }
        let interval = timestamp.timeIntervalSince(startTime)
        guard interval > TimeInterval(self.codec!.height) / 1000.0 else { return }

        // Encode.
        do {
            try encoder.write(sample: sampleBuffer, timestamp: timestamp)
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
