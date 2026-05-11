// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest
import CoreMedia
import AVFoundation
import Testing

private final class MockEncoder: VideoEncoder, @unchecked Sendable {
    typealias WriteCallback = @Sendable (_ sample: CMSampleBuffer, _ timestamp: Date, _ forceKeyFrame: Bool) -> Void
    private let callback: WriteCallback

    init(_ writeCallback: @escaping WriteCallback) {
        self.callback = writeCallback
    }

    func write(sample: CMSampleBuffer, timestamp: Date, forceKeyFrame: Bool) throws {
        self.callback(sample, timestamp, forceKeyFrame)
    }
}

/// Test double for ``MoQSink`` — lets tests drive status and observe publish calls.
final class MockSink: MoQSink, @unchecked Sendable {
    typealias PublishCallback = (_ groupId: UInt64, _ objectId: UInt64) -> Void

    let fullTrackName: FullTrackName
    var mockCanPublish = false
    var onPublish: PublishCallback?
    private var onStatus: (@Sendable (QPublishTrackHandlerStatus) -> Void)?

    private var mockStatus: QPublishTrackHandlerStatus = .notConnected
    var status: QPublishTrackHandlerStatus { self.mockStatus }
    var canPublish: Bool { self.mockCanPublish }

    init(fullTrackName: FullTrackName) {
        self.fullTrackName = fullTrackName
    }

    func setCallbacks(onStatus: @escaping @Sendable (QPublishTrackHandlerStatus) -> Void,
                      onMetrics: @escaping @Sendable (QPublishTrackMetrics) -> Void) {
        self.onStatus = onStatus
    }

    /// Deliver a status to the installed publication callback.
    func fireStatus(_ status: QPublishTrackHandlerStatus) {
        self.mockStatus = status
        self.onStatus?(status)
    }

    func publishObject(_ headers: QObjectHeaders,
                       data: Data,
                       extensions: HeaderExtensions?,
                       immutableExtensions: HeaderExtensions?,
                       streamHeaderProperties: QStreamHeaderProperties?) -> QPublishObjectStatus {
        self.onPublish?(headers.groupId, headers.objectId)
        return .ok
    }

    func endSubgroup(groupId: UInt64, subgroupId: UInt64, completed: Bool) {}
}

enum TestError: Error {
    case noCamera
}

private func makeProfile() -> Profile {
    Profile(qualityProfile: "",
            expiry: [1, 2],
            priorities: [1, 2],
            namespace: [""])
}

private func makeConfig(height: Int32) -> VideoCodecConfig {
    VideoCodecConfig(codec: .h264,
                     bitrate: 1_000_000,
                     fps: 30,
                     width: 1920,
                     height: height,
                     bitrateType: .average)
}

private func makePublication(encoder: MockEncoder,
                             sink: MoQSink,
                             height: Int32 = 1920,
                             stagger: Bool = false,
                             keyFrameOnUpdate: Bool = false) throws -> H264Publication {
    guard let device = AVCaptureDevice.systemPreferredCamera else {
        throw TestError.noCamera
    }
    let profile = makeProfile()
    return try H264Publication(profile: profile,
                               config: makeConfig(height: height),
                               metricsSubmitter: nil,
                               granularMetrics: false,
                               encoderFactory: { _, _ in encoder },
                               device: device,
                               endpointId: "",
                               relayId: "",
                               stagger: stagger,
                               verbose: true,
                               keyFrameOnUpdate: keyFrameOnUpdate,
                               sframeContext: nil,
                               mediaInterop: false,
                               appExtensionMode: .mutable,
                               sink: sink)
}

final class TestVideoPublication: XCTestCase {
    func testPublicationStartDelay() throws {
        var shouldFire = false
        let mockEncoder = MockEncoder { _, _, _ in
            guard shouldFire else {
                XCTFail("Encoder fired before stagger delay elapsed")
                return
            }
        }

        let height: Int32 = 1080
        let sink = MockSink(fullTrackName: try makeProfile().getFullTrackName())
        sink.mockCanPublish = true
        let publication: H264Publication
        do {
            publication = try makePublication(encoder: mockEncoder,
                                              sink: sink,
                                              height: height,
                                              stagger: true)
        } catch TestError.noCamera {
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
        guard AVCaptureDevice.systemPreferredCamera != nil else { return }
        try await confirmation(expectedCount: 2) { confirmation in
            let encoder = MockEncoder { _, _, _ in confirmation() }
            let sink = MockSink(fullTrackName: try makeProfile().getFullTrackName())
            let publication = try makePublication(encoder: encoder, sink: sink)
            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [],
                                            sampleSizes: [])
            let startDate = Date.now
            // When canPublish is false, onFrame should not encode
            sink.mockCanPublish = false
            publication.onFrame(sample, timestamp: startDate)
            // When canPublish is true, onFrame should encode (confirmation #1)
            sink.mockCanPublish = true
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
        guard AVCaptureDevice.systemPreferredCamera != nil else { return }
        var status: QPublishTrackHandlerStatus?
        try await confirmation(expectedCount: 3) { confirmation in
            let encoder = MockEncoder { _, _, keyFrame in
                #expect(keyFrame == (status == toSet))
                confirmation()
            }

            var lastObjectId: UInt64?
            let sink = MockSink(fullTrackName: try makeProfile().getFullTrackName())
            sink.onPublish = { _, objectId in
                // When this is a key frame, object ID should be 0.
                if status == toSet {
                    #expect(lastObjectId != 0)
                    #expect(objectId == 0)
                }
                lastObjectId = objectId
            }
            // Enable publishing for all frames in this test
            sink.mockCanPublish = true

            let publication = try makePublication(encoder: encoder,
                                                  sink: sink,
                                                  keyFrameOnUpdate: true)

            let sample = try CMSampleBuffer(dataBuffer: nil,
                                            formatDescription: nil,
                                            numSamples: 1,
                                            sampleTimings: [],
                                            sampleSizes: [])
            // pframe.
            status = .ok
            sink.fireStatus(status!)
            publication.onFrame(sample, timestamp: .now)

            // key frame.
            status = toSet
            sink.fireStatus(status!)
            publication.onFrame(sample, timestamp: .now)

            // pframe.
            status = .ok
            sink.fireStatus(status!)
            publication.onFrame(sample, timestamp: .now)
        }
    }
}
