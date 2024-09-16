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
    func testPublicationStartDelay() throws {
        var shouldFire = false
        let mockEncoder = MockEncoder {
            guard shouldFire else {
                XCTFail()
                return
            }
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
                                      height: 960,
                                      bitrateType: .average)

        let publication = try H264Publication(profile: .init(qualityProfile: "", expiry: [], priorities: [], namespace: ""),
                                              config: config,
                                              metricsSubmitter: nil,
                                              reliable: true,
                                              granularMetrics: false,
                                              encoder: mockEncoder,
                                              device: device,
                                              endpointId: "",
                                              relayId: "")

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
        let advancedLessThanHeight = now.addingTimeInterval(TimeInterval(config.height) / 1000 / 2)
        publication.onFrame(sample, timestamp: advancedLessThanHeight)

        // This one should.
        let advancedMoreThanHeight = now.addingTimeInterval(TimeInterval(config.height) / 1000)
        shouldFire = true
        publication.onFrame(sample, timestamp: advancedMoreThanHeight)
    }
}
