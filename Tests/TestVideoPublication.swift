// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest
import CoreMedia
import AVFoundation
import Testing

private class MockEncoder: VideoEncoder {
    var frameRate: Float64?
    typealias WriteCallback = (_ sample: CMSampleBuffer, _ timestamp: Date, _ forceKeyFrame: Bool) -> Void
    private let callback: WriteCallback

    init(_ writeCallback: @escaping WriteCallback) {
        self.callback = writeCallback
    }

    func write(sample: CMSampleBuffer, timestamp: Date, forceKeyFrame: Bool) throws {
        self.callback(sample, timestamp, forceKeyFrame)
    }

    func setCallback(_ callback: @escaping EncodedCallback, userData: UnsafeRawPointer?) {
        // NOOP.
    }
}

class FakeH264Publication: H264Publication {
    typealias PublishCallback = (_ groupId: UInt64,
                                 _ objectId: UInt64) -> Void
    private let publishNotify: PublishCallback
    private var currentStatus: QPublishTrackHandlerStatus = .notConnected

    required init(profile: Profile,
                  config: VideoCodecConfig,
                  metricsSubmitter: (any MetricsSubmitter)?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: any VideoEncoder,
                  device: AVCaptureDevice,
                  endpointId: String,
                  relayId: String,
                  stagger: Bool,
                  verbose: Bool,
                  notify: @escaping PublishCallback) throws {
        self.publishNotify = notify
        try super.init(profile: profile,
                       config: config,
                       metricsSubmitter: metricsSubmitter,
                       reliable: reliable,
                       granularMetrics: granularMetrics,
                       encoder: encoder,
                       device: device,
                       endpointId: endpointId,
                       relayId: relayId,
                       stagger: stagger,
                       verbose: verbose)
    }

    required init(profile: Profile,
                  config: VideoCodecConfig,
                  metricsSubmitter: (any MetricsSubmitter)?,
                  reliable: Bool,
                  granularMetrics: Bool,
                  encoder: any VideoEncoder,
                  device: AVCaptureDevice,
                  endpointId: String,
                  relayId: String,
                  stagger: Bool,
                  verbose: Bool) throws {
        fatalError("init(profile:config:metricsSubmitter:reliable:granularMetrics:encoder:device:endpointId:relayId:stagger:verbose:) has not been implemented")
    }

    override func publish(groupId: UInt64,
                          objectId: UInt64,
                          data: Data,
                          priority: UnsafePointer<UInt8>?,
                          ttl: UnsafePointer<UInt16>?,
                          extensions: [NSNumber: Data]) -> QPublishObjectStatus {
        self.publishNotify(groupId, objectId)
        return super.publish(groupId: groupId,
                             objectId: objectId,
                             data: data,
                             priority: priority,
                             ttl: ttl,
                             extensions: extensions)
    }

    override func statusChanged(_ status: QPublishTrackHandlerStatus) {
        super.statusChanged(status)
        self.currentStatus = status
    }

    override func getStatus() -> QPublishTrackHandlerStatus {
        self.currentStatus
    }
}

enum TestError: Error {
    case noCamera
}

private func makePublication(_ encoder: MockEncoder, height: Int32, stagger: Bool) throws -> H264Publication {
    guard let device = AVCaptureDevice.systemPreferredCamera else {
        throw TestError.noCamera
    }

    // Publications should be delayed by their height in ms.
    let config = VideoCodecConfig(codec: .h264,
                                  bitrate: 1_000_000,
                                  fps: 30,
                                  width: 1920,
                                  height: height,
                                  bitrateType: .average)

    return try .init(profile: .init(qualityProfile: "",
                                    expiry: [1, 2],
                                    priorities: [1, 2],
                                    namespace: [""]),
                     config: config,
                     metricsSubmitter: nil,
                     reliable: true,
                     granularMetrics: false,
                     encoder: encoder,
                     device: device,
                     endpointId: "",
                     relayId: "",
                     stagger: stagger,
                     verbose: true)
}

final class TestVideoPublication: XCTestCase {
    func testPublicationStartDelay() throws {
        var shouldFire = false
        let mockEncoder = MockEncoder { _, _, _ in
            guard shouldFire else {
                XCTFail()
                return
            }
        }

        let height: Int32 = 1080
        guard let publication = try? makePublication(mockEncoder, height: height, stagger: true) else {
            _ = XCTSkip("Can't test without a camera")
            return
        }

        // Mock sample.
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [],
                                        sampleSizes: [])

        // Let's make the start time, now.
        let now = Date.now
        // This one should not fire.
        publication.onFrame(sample, timestamp: now)

        // This one still should not fire.
        let advancedLessThanHeight = now.addingTimeInterval(TimeInterval(height) / 1000 / 2)
        publication.onFrame(sample, timestamp: advancedLessThanHeight)

        // This one should.
        let advancedMoreThanHeight = now.addingTimeInterval(TimeInterval(height) / 1000)
        shouldFire = true
        publication.onFrame(sample, timestamp: advancedMoreThanHeight)
    }

    func testMetrics() throws {
        let minMax = QMinMaxAvg(min: 0, max: 1, avg: 2, value_sum: 3, value_count: 4)
        let metrics = QPublishTrackMetrics(lastSampleTime: 1,
                                           bytesPublished: 2,
                                           objectsPublished: 3,
                                           quic: .init(tx_buffer_drops: 0,
                                                       tx_queue_discards: 1,
                                                       tx_queue_expired: 2,
                                                       tx_delayed_callback: 3,
                                                       tx_reset_wait: 4,
                                                       tx_queue_size: minMax,
                                                       tx_callback_ms: minMax,
                                                       tx_object_duration_us: minMax))

        guard let publication = try? makePublication(.init({_, _, _ in}), height: 1080, stagger: false) else {
            _ = XCTSkip("Can't test without a camera")
            return
        }
        publication.metricsSampled(metrics)
    }
}

let badStatuses: [QPublishTrackHandlerStatus?] = [ nil,
                                                   .announceNotAuthorized,
                                                   .noSubscribers,
                                                   .notAnnounced,
                                                   .notConnected,
                                                   .pendingAnnounceResponse,
                                                   .sendingUnannounce]

@Suite struct VideoPublicationTests {
    @Test("Only encode on valid status", arguments: badStatuses)
    func testEncodeWithStatus(_ status: QPublishTrackHandlerStatus?) async throws {
        try await confirmation(expectedCount: 2) { confirmation in
            let encoder = MockEncoder { _, _, _ in confirmation() }
            guard let device = AVCaptureDevice.systemPreferredCamera else {
                _ = XCTSkip("Can't test without a camera")
                return
            }
            let config = VideoCodecConfig(codec: .h264,
                                          bitrate: 1_000_000,
                                          fps: 30,
                                          width: 1920,
                                          height: 1920,
                                          bitrateType: .average)
            let publication = try FakeH264Publication(profile: .init(qualityProfile: "",
                                                                     expiry: [1, 2],
                                                                     priorities: [1, 2],
                                                                     namespace: [""]),
                                                      config: config,
                                                      metricsSubmitter: nil,
                                                      reliable: true,
                                                      granularMetrics: false,
                                                      encoder: encoder,
                                                      device: device,
                                                      endpointId: "",
                                                      relayId: "",
                                                      stagger: false,
                                                      verbose: false,
                                                      notify: ({_, _ in }))
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [],
                                            sampleSizes: [])
            let startDate = Date.now
            if let status = status {
                publication.statusChanged(status)
            }
            publication.onFrame(sample, timestamp: startDate)
            publication.statusChanged(.ok)
            publication.onFrame(sample, timestamp: startDate)
            publication.statusChanged(.subscriptionUpdated)
            publication.onFrame(sample, timestamp: startDate)
        }
    }

    @Test("Keyframe on subscribe update")
    func testKeyFrameOnPublishFailure() async throws {
        var status: QPublishTrackHandlerStatus?
        try await confirmation(expectedCount: 3) { confirmation in
            let encoder = MockEncoder { _, _, keyFrame in
                #expect(keyFrame == (status == .subscriptionUpdated))
                confirmation()
            }
            guard let device = AVCaptureDevice.systemPreferredCamera else {
                _ = XCTSkip("Can't test without a camera")
                return
            }

            // Publications should be delayed by their height in ms.
            let config = VideoCodecConfig(codec: .h264,
                                          bitrate: 1_000_000,
                                          fps: 30,
                                          width: 1920,
                                          height: 1920,
                                          bitrateType: .average)
            var lastObjectId: UInt64?
            let publication = try FakeH264Publication(profile: .init(qualityProfile: "",
                                                                     expiry: [1, 2],
                                                                     priorities: [1, 2],
                                                                     namespace: [""]),
                                                      config: config,
                                                      metricsSubmitter: nil,
                                                      reliable: true,
                                                      granularMetrics: false,
                                                      encoder: encoder,
                                                      device: device,
                                                      endpointId: "",
                                                      relayId: "",
                                                      stagger: false,
                                                      verbose: true) { _, objectId in
                // When this is a key frame, object ID should be 0.
                if status == .subscriptionUpdated {
                    #expect(lastObjectId != 0)
                    #expect(objectId == 0)
                }
                lastObjectId = objectId
            }
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [],
                                            sampleSizes: [])
            // pframe.
            status = .ok
            publication.statusChanged(status!)
            publication.onFrame(sample, timestamp: .now)

            // key frame.
            status = .subscriptionUpdated
            publication.statusChanged(status!)
            publication.onFrame(sample, timestamp: .now)

            // pframe.
            status = .ok
            publication.statusChanged(status!)
            publication.onFrame(sample, timestamp: .now)
        }
    }
}
