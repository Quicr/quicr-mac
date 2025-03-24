// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest
import CoreMedia
import Testing

final class TestVideoSubscriptionSet: XCTestCase {
    private func testImage(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCMPixelFormat_24RGB,
                                         nil,
                                         &buffer)
        guard result == .zero,
              let buffer = buffer else { throw "Failed: \(result)" }
        return buffer
    }

    private func getQualities(discontinous: [Bool], timing: [CMTime]? = nil) throws -> [VideoSubscriptionSet.SimulreceiveItem] {
        let highestBuffer = try testImage(width: 1920, height: 1280)
        let highestImage = AvailableImage(image: try .init(imageBuffer: highestBuffer,
                                                           formatDescription: .init(imageBuffer: highestBuffer),
                                                           sampleTiming: .init(duration: .invalid,
                                                                               presentationTimeStamp: timing?[0] ?? .init(value: 1, timescale: 1),
                                                                               decodeTimeStamp: .invalid)),
                                          fps: 30,
                                          discontinous: discontinous[0])
        let highest = VideoSubscriptionSet.SimulreceiveItem(fullTrackName: try .init(namespace: ["1"], name: ""), image: highestImage)

        let mediumBuffer = try testImage(width: 1280, height: 960)
        let mediumImage = AvailableImage(image: try .init(imageBuffer: mediumBuffer,
                                                          formatDescription: .init(imageBuffer: mediumBuffer),
                                                          sampleTiming: .init(duration: .invalid,
                                                                              presentationTimeStamp: timing?[1] ?? .init(value: 1, timescale: 1),
                                                                              decodeTimeStamp: .invalid)),
                                         fps: 30,
                                         discontinous: discontinous[1])
        let medium = VideoSubscriptionSet.SimulreceiveItem(fullTrackName: try .init(namespace: ["2"], name: ""), image: mediumImage)

        let lowerBuffer = try testImage(width: 1280, height: 960)
        let lowerImage = AvailableImage(image: try .init(imageBuffer: lowerBuffer,
                                                         formatDescription: .init(imageBuffer: lowerBuffer),
                                                         sampleTiming: .init(duration: .invalid,
                                                                             presentationTimeStamp: timing?[2] ?? .init(value: 1, timescale: 1),
                                                                             decodeTimeStamp: .invalid)),
                                        fps: 30,
                                        discontinous: discontinous[2])
        let lower = VideoSubscriptionSet.SimulreceiveItem(fullTrackName: try .init(namespace: ["3"], name: ""), image: lowerImage)

        return [highest, medium, lower]
    }

    func testOnlyConsiderOldest() throws {
        // Only the subset of frames matching the oldest timestamp should be considered.
        let choices = try getQualities(discontinous: .init(repeating: false, count: 3),
                                       timing: [.init(value: 2, timescale: 1),
                                                .init(value: 1, timescale: 1),
                                                .init(value: 1, timescale: 1)])
        var inOutChoices = choices as any Collection<VideoSubscriptionSet.SimulreceiveItem>
        let result = VideoSubscriptionSet.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, _):
            XCTAssertEqual(item, choices[1])
        default:
            XCTFail()
        }

    }

    func testNothingGivesNothing() {
        let choices: [VideoSubscriptionSet.SimulreceiveItem] = []
        var inOutChoices = choices as any Collection<VideoSubscriptionSet.SimulreceiveItem>
        XCTAssertNil(VideoSubscriptionSet.makeSimulreceiveDecision(choices: &inOutChoices))
    }

    func testOneReturnsItself() throws {
        let all = try getQualities(discontinous: .init(repeating: false, count: 3))
        let choices = [all[0]]
        var inOutChoices = choices as any Collection<VideoSubscriptionSet.SimulreceiveItem>
        let result = VideoSubscriptionSet.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .onlyChoice(let item):
            XCTAssertEqual(item, choices[0])
        default:
            XCTFail()
        }
    }

    func testHighestResolutionWhenAllPristine() throws {
        // When we have all available pristine images, highest quality should be picked.
        let choices = try getQualities(discontinous: .init(repeating: false, count: 3))
        var inOutChoices = choices as any Collection<VideoSubscriptionSet.SimulreceiveItem>
        let result = VideoSubscriptionSet.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, let pristine):
            XCTAssertNotEqual(item, choices[1])
            XCTAssertNotEqual(item, choices[2])
            XCTAssertEqual(item, choices[0])
            XCTAssert(pristine)
        default:
            XCTFail()
        }
    }

    func testLowerPristineWhenHigherIsNot() throws {
        // When we have all available images, highest pristine should be picked.
        let choices = try getQualities(discontinous: [true, false, false])
        var inOutChoices = choices as any Collection<VideoSubscriptionSet.SimulreceiveItem>
        let result = VideoSubscriptionSet.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, let pristine):
            XCTAssertNotEqual(item, choices[0])
            XCTAssertNotEqual(item, choices[2])
            XCTAssertEqual(item, choices[1])
            XCTAssert(pristine)
        default:
            XCTFail()
        }
    }

    func testAllDiscontinous() throws {
        // When we have all discontinous images, highest resolution should be picked.
        let choices = try getQualities(discontinous: .init(repeating: true, count: 3))
        var inOutChoices = choices as any Collection<VideoSubscriptionSet.SimulreceiveItem>
        let result = VideoSubscriptionSet.makeSimulreceiveDecision(choices: &inOutChoices)
        XCTAssertNotNil(result)
        switch result {
        case .highestRes(let item, let pristine):
            XCTAssertFalse(pristine)
            XCTAssertNotEqual(item, choices[1])
            XCTAssertNotEqual(item, choices[2])
            XCTAssertEqual(item, choices[0])
        default:
            XCTFail()
        }
    }
}

struct VideoSubscriptionSetTests {
    static let now = Date.now
    static let pastTimestamp = Self.now.addingTimeInterval(-10).timeIntervalSince1970
    static let futureTimestamp = Self.now.addingTimeInterval(10).timeIntervalSince1970

    @MainActor
    @Test("Test Timestamp Diff", arguments: [Self.now.timeIntervalSince1970,
                                             Self.pastTimestamp,
                                             Self.futureTimestamp])
    func testTimestampDiff(timestamp: TimeInterval) throws {
        let set = try VideoSubscriptionSet(subscription: .init(mediaType: "",
                                                               sourceName: "",
                                                               sourceID: "",
                                                               label: "",
                                                               participantId: .init(1),
                                                               profileSet: .init(type: "",
                                                                                 profiles: [.init(qualityProfile: "",
                                                                                                  expiry: nil,
                                                                                                  priorities: nil,
                                                                                                  namespace: [])])),
                                           participants: .init(),
                                           metricsSubmitter: nil,
                                           videoBehaviour: .freeze,
                                           reliable: true,
                                           granularMetrics: true,
                                           jitterBufferConfig: .init(),
                                           simulreceive: .visualizeOnly,
                                           qualityMissThreshold: 1,
                                           pauseMissThreshold: 1,
                                           pauseResume: false,
                                           endpointId: "",
                                           relayId: "",
                                           codecFactory: MockCodecFactory(),
                                           joinDate: .now,
                                           cleanupTime: 10,
                                           slidingWindowTime: 10)
        try set.receivedObject(.init(namespace: [], name: ""), timestamp: timestamp, when: Self.now, cached: false)
    }
}

extension AvailableImage: Equatable {
    public static func == (lhs: AvailableImage, rhs: AvailableImage) -> Bool {
        lhs.image == rhs.image
    }
}
