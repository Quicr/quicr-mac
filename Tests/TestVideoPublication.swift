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
    var mockCanPublish: Bool = false
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
                  keyFrameOnUpdate: Bool,
                  notify: @escaping PublishCallback,
                  sink: MoQSink) throws {
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
                       verbose: verbose,
                       keyFrameOnUpdate: keyFrameOnUpdate,
                       sframeContext: nil,
                       mediaInterop: false,
                       sink: sink)
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
                  verbose: Bool,
                  keyFrameOnUpdate: Bool,
                  sframeContext: SendSFrameContext?,
                  mediaInterop: Bool,
                  sink: MoQSink) throws {
        // swiftlint:disable:next line_length
        fatalError("init(profile:config:metricsSubmitter:reliable:granularMetrics:encoder:device:endpointId:relayId:stagger:verbose:keyFrameOnUpdate:sframeContext:mediaInterop:sink:) has not been implemented")
    }

    override func publish(groupId: UInt64,
                          subgroupId: UInt64,
                          objectId: UInt64,
                          data: Data,
                          priority: UnsafePointer<UInt8>?,
                          ttl: UnsafePointer<UInt16>?,
                          extensions: HeaderExtensions?,
                          immutableExtensions: HeaderExtensions?) -> QPublishObjectStatus {
        self.publishNotify(groupId, objectId)
        return super.publish(groupId: groupId,
                             subgroupId: subgroupId,
                             objectId: objectId,
                             data: data,
                             priority: priority,
                             ttl: ttl,
                             extensions: extensions,
                             immutableExtensions: immutableExtensions)
    }

    override func canPublish() -> Bool {
        self.mockCanPublish
    }

    override func sinkStatusChanged(_ status: QPublishTrackHandlerStatus) {
        super.sinkStatusChanged(status)
        self.currentStatus = status
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

    let profile = Profile(qualityProfile: "",
                          expiry: [1, 2],
                          priorities: [1, 2],
                          namespace: [""])
    let sink = QPublishTrackHandlerSink(fullTrackName: try profile.getFullTrackName(),
                                        trackMode: .stream,
                                        defaultPriority: 1,
                                        defaultTTL: 1,
                                        )
    return try .init(profile: profile,
                     config: config,
                     metricsSubmitter: nil,
                     reliable: true,
                     granularMetrics: false,
                     encoder: encoder,
                     device: device,
                     endpointId: "",
                     relayId: "",
                     stagger: stagger,
                     verbose: true,
                     keyFrameOnUpdate: false,
                     sframeContext: nil,
                     mediaInterop: false,
                     sink: sink)
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
}

@Suite struct VideoPublicationTests {
    @Test("Only encode when canPublish is true")
    func testEncodeWithCanPublish() async throws {
        guard let device = AVCaptureDevice.systemPreferredCamera else {
            _ = XCTSkip("Can't test without a camera")
            return
        }
        try await confirmation(expectedCount: 2) { confirmation in
            let encoder = MockEncoder { _, _, _ in confirmation() }
            let config = VideoCodecConfig(codec: .h264,
                                          bitrate: 1_000_000,
                                          fps: 30,
                                          width: 1920,
                                          height: 1920,
                                          bitrateType: .average)
            let profile = Profile(qualityProfile: "",
                                  expiry: [1, 2],
                                  priorities: [1, 2],
                                  namespace: [""])
            let sink = QPublishTrackHandlerSink(fullTrackName: try profile.getFullTrackName(),
                                                trackMode: .stream,
                                                defaultPriority: 1,
                                                defaultTTL: 1,
                                                )
            let publication = try FakeH264Publication(profile: profile,
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
                                                      keyFrameOnUpdate: false,
                                                      notify: ({_, _ in }),
                                                      sink: sink)
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [],
                                            sampleSizes: [])
            let startDate = Date.now
            // When canPublish is false, onFrame should not encode
            publication.mockCanPublish = false
            publication.onFrame(sample, timestamp: startDate)
            // When canPublish is true, onFrame should encode (confirmation #1)
            publication.mockCanPublish = true
            publication.onFrame(sample, timestamp: startDate)
            // Still true, should encode again (confirmation #2)
            publication.onFrame(sample, timestamp: startDate)
        }
    }

    @Test("Keyframe on subscribe update")
    func testKeyFrameOnPublishFailure() async throws {
        try await self.testKeyFrame(.subscriptionUpdated)
    }

    @Test("Keyframe on new group")
    func testKeyFrameOnNewGroup() async throws {
        try await self.testKeyFrame(.newGroupRequested)
    }

    func testKeyFrame(_ toSet: QPublishTrackHandlerStatus) async throws {
        guard let device = AVCaptureDevice.systemPreferredCamera else {
            _ = XCTSkip("Can't test without a camera")
            return
        }
        var status: QPublishTrackHandlerStatus?
        try await confirmation(expectedCount: 3) { confirmation in
            let encoder = MockEncoder { _, _, keyFrame in
                #expect(keyFrame == (status == toSet))
                confirmation()
            }

            // Publications should be delayed by their height in ms.
            let config = VideoCodecConfig(codec: .h264,
                                          bitrate: 1_000_000,
                                          fps: 30,
                                          width: 1920,
                                          height: 1920,
                                          bitrateType: .average)
            var lastObjectId: UInt64?
            let profile = Profile(qualityProfile: "",
                                  expiry: [1, 2],
                                  priorities: [1, 2],
                                  namespace: [""])
            let sink = QPublishTrackHandlerSink(fullTrackName: try profile.getFullTrackName(),
                                                trackMode: .stream,
                                                defaultPriority: 1,
                                                defaultTTL: 1,
                                                )
            let publication = try FakeH264Publication(profile: profile,
                                                      config: config,
                                                      metricsSubmitter: nil,
                                                      reliable: true,
                                                      granularMetrics: false,
                                                      encoder: encoder,
                                                      device: device,
                                                      endpointId: "",
                                                      relayId: "",
                                                      stagger: false,
                                                      verbose: true,
                                                      keyFrameOnUpdate: true,
                                                      notify: { _, objectId in
                                                        // When this is a key frame, object ID should be 0.
                                                        if status == toSet {
                                                            #expect(lastObjectId != 0)
                                                            #expect(objectId == 0)
                                                        }
                                                        lastObjectId = objectId
                                                      },
                                                      sink: sink)
            // Enable publishing for all frames in this test
            publication.mockCanPublish = true

            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [],
                                            sampleSizes: [])
            // pframe.
            status = .ok
            publication.sinkStatusChanged(status!)
            publication.onFrame(sample, timestamp: .now)

            // key frame.
            status = toSet
            publication.sinkStatusChanged(status!)
            publication.onFrame(sample, timestamp: .now)

            // pframe.
            status = .ok
            publication.sinkStatusChanged(status!)
            publication.onFrame(sample, timestamp: .now)
        }
    }
}
