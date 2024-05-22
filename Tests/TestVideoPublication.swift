@testable import Decimus
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

    func write(sample: CMSampleBuffer, captureTime: Date) throws {
        self.callback()
    }

    func setCallback(_ callback: @escaping EncodedCallback) {
        // NOOP.
    }
}

private class MockDelegate: QPublishObjectDelegateObjC {
    typealias Callback = (String, Data, Bool) -> Void
    private let callback: Callback

    init(_ callback: @escaping Callback) {
        self.callback = callback
    }

    func publishObject(_ quicrNamespace: String!, data: Data!, group groupFlag: Bool) {
        self.callback(quicrNamespace, data, groupFlag)
    }

    func publishObject(_ quicrNamespace: String!, data dataPtr: UnsafeRawPointer!, length dataLen: Int, group groupFlag: Bool) {
        self.callback(quicrNamespace, Data(bytesNoCopy: .init(mutating: dataPtr), count: dataLen, deallocator: .none), groupFlag)
    }
}

final class TestVideoPublication: XCTestCase {
    func testPublicationStartDelay() throws {
        let mockDelegate = MockDelegate { _, _, _ in
            XCTFail()
            return
        }

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
                                      bitrateType: .average,
                                      limit1s: 1_000_000)
        let publication = try H264Publication(namespace: "1",
                                              publishDelegate: mockDelegate,
                                              sourceID: "1",
                                              config: config,
                                              metricsSubmitter: nil,
                                              reliable: true,
                                              granularMetrics: false,
                                              encoder: mockEncoder,
                                              device: device)

        // Mock sample.
        let sample = try CMSampleBuffer(dataBuffer: nil,
                                        formatDescription: nil,
                                        numSamples: 1,
                                        sampleTimings: [],
                                        sampleSizes: [])

        // Let's make the start time, now.
        let now = Date.now
        // This one should not fire.
        publication.onFrame(sample, captureTime: now)

        // This one still should not fire.
        let advancedLessThanHeight = now.addingTimeInterval(TimeInterval(config.height) / 1000 / 2)
        publication.onFrame(sample, captureTime: advancedLessThanHeight)

        // This one should.
        let advancedMoreThanHeight = now.addingTimeInterval(TimeInterval(config.height) / 1000)
        shouldFire = true
        publication.onFrame(sample, captureTime: advancedMoreThanHeight)
    }
}
