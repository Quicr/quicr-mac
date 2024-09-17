// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest
import CoreMedia
import AVFoundation

private class MockEncoder: VideoEncoder {
    var frameRate: Float64?
    typealias WriteCallback = () -> Void
    private let callback: WriteCallback

    init(_ writeCallback: @escaping WriteCallback) {
        self.callback = writeCallback
    }

    func write(sample: CMSampleBuffer, timestamp: Date) throws {
        self.callback()
    }

    func setCallback(_ callback: @escaping EncodedCallback, userData: UnsafeRawPointer?) {
        // NOOP.
    }
}

final class TestVideoPublication: XCTestCase {

    private func makePublication(_ encoder: MockEncoder, height: Int32) throws -> H264Publication {
        guard let device = AVCaptureDevice.systemPreferredCamera else {
            throw XCTSkip("Can't test without a camera")
        }

        // Publications should be delayed by their height in ms.
        let config = VideoCodecConfig(codec: .h264,
                                      bitrate: 1_000_000,
                                      fps: 30,
                                      width: 1920,
                                      height: height,
                                      bitrateType: .average)

        return try .init(profile: .init(qualityProfile: "",
                                        expiry: [],
                                        priorities: [],
                                        namespace: ""),
                         config: config,
                         metricsSubmitter: nil,
                         reliable: true,
                         granularMetrics: false,
                         encoder: encoder,
                         device: device,
                         endpointId: "",
                         relayId: "")
    }

    func testPublicationStartDelay() throws {
        var shouldFire = false
        let mockEncoder = MockEncoder {
            guard shouldFire else {
                XCTFail()
                return
            }
        }

        let height: Int32 = 1080
        let publication = try self.makePublication(mockEncoder, height: height)

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
        let publication = try self.makePublication(.init({
        }), height: 1080)
        publication.metricsSampled(metrics)
    }
}
