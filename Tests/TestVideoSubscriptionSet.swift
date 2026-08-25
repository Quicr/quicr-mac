// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR
import XCTest
import CoreMedia
import Synchronization
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
    static let now = Ticks.now
    static let pastTimestamp = Self.now.hostDate.addingTimeInterval(-10).timeIntervalSince1970
    static let futureTimestamp = Self.now.hostDate.addingTimeInterval(10).timeIntervalSince1970

    private func makeObjectReceived(timestamp: TimeInterval?) -> ObjectReceived {
        .init(timestamp: timestamp,
              when: .now,
              cached: false,
              headers: .init(groupId: 0,
                             subgroupId: 0,
                             objectId: 0,
                             payloadLength: 0,
                             status: .available,
                             priority: nil,
                             ttl: nil),
              usable: true,
              publishTimestamp: nil)
    }

    @MainActor
    private func makeParticipant() -> VideoParticipant {
        .init(id: "participant",
              startDate: .now,
              subscribeDate: .now,
              participantId: .init(1),
              activeSpeakerStats: nil,
              config: .init(calculateLatency: false,
                            slidingWindowTime: 1))
    }

    @MainActor
    private func makeSimulreceiveSet(participants: VideoParticipants) throws -> VideoSubscriptionSet {
        try VideoSubscriptionSet(subscription: .init(mediaType: "",
                                                     sourceName: "",
                                                     sourceID: "participant",
                                                     label: "",
                                                     participantId: .init(1),
                                                     profileSet: .init(type: "",
                                                                       profiles: [.init(qualityProfile: "",
                                                                                        expiry: nil,
                                                                                        priorities: nil,
                                                                                        namespace: ["participant"])])),
                                 participants: participants,
                                 metricsSubmitter: nil,
                                 videoBehaviour: .freeze,
                                 granularMetrics: true,
                                 jitterBufferConfig: .init(),
                                 simulreceive: .enable,
                                 qualityMissThreshold: 1,
                                 pauseMissThreshold: 1,
                                 pauseResume: false,
                                 endpointId: "",
                                 relayId: "",
                                 codecFactory: MockCodecFactory(),
                                 joinDate: .now,
                                 activeSpeakerStats: nil,
                                 cleanupTime: 10,
                                 slidingWindowTime: 10,
                                 config: .init(calculateLatency: false,
                                               qualityHitThreshold: 1))
    }

    @MainActor
    private func makeVideoSubscription(participants: VideoParticipants,
                                       namespace: [String] = ["0"],
                                       statusChanged: VideoSubscription.VideoStatusCallback? = nil,
                                       callback: VideoSubscription.Callback? = nil) async throws -> VideoSubscription {
        try await TestVideoSubscription().makeSubscription(.video(),
                                                           fetchThreshold: 0,
                                                           ngThreshold: 0,
                                                           namespace: namespace,
                                                           callback: callback,
                                                           participants: participants,
                                                           simulreceive: .enable,
                                                           statusChanged: statusChanged)
    }

    @MainActor
    @Test("Removed subscription callbacks cannot affect a same-name replacement")
    func testRemovedSubscriptionCallbacksCannotAffectReplacement() async throws {
        let participants = VideoParticipants()
        let set = try self.makeSimulreceiveSet(participants: participants)
        let deferred = Mutex<(VideoSubscription, ObjectReceived)?>(nil)
        let subscription = try await self.makeVideoSubscription(
            participants: participants,
            statusChanged: { source, status in
                guard status == .notSubscribed else { return }
                _ = set.removeHandler(source)
            },
            callback: { source, details in
                deferred.withLock { $0 = (source, details) }
            })
        let resolvedFullTrackName = FullTrackName(subscription.getFullTrackName())
        try set.addHandler(subscription)

        subscription.mockObject(groupId: 0,
                                objectId: 0,
                                immutableExtensions: .video(sequenceNumber: 1))
        let captured = deferred.withLock { $0 }
        let callback = try #require(captured)
        _ = set.removeHandler(resolvedFullTrackName)

        let replacement = try await self.makeVideoSubscription(participants: participants)
        try set.addHandler(replacement)
        set.receivedObject(callback.0, details: callback.1)
        subscription.statusChanged(.notSubscribed)

        #expect(set.getHandlers()[resolvedFullTrackName] === replacement)
        #expect(participants.participants.compactMap(\.value).isEmpty)
        #expect(set.getMediaState() == .subscribed)
    }

    @MainActor
    @Test("A released participant registration is pruned and can be replaced")
    func testReleasedParticipantCanBeReplaced() async throws {
        let participants = VideoParticipants()
        var participant: VideoParticipant? = self.makeParticipant()
        var registration: VideoParticipantRegistration? = try participants.register(participant!)

        participant = nil
        #expect(participants.participants.compactMap(\.value).count == 1)
        registration = nil
        for _ in 0..<20 where !participants.participants.isEmpty {
            await Task.yield()
        }

        #expect(participants.participants.compactMap(\.value).isEmpty)
        let replacement = self.makeParticipant()
        registration = try participants.register(replacement)
        #expect(participants.participants.compactMap(\.value).first === replacement)
        _ = registration
    }

    @MainActor
    @Test("Invalidated registration cannot touch or remove its replacement")
    func testInvalidatedRegistrationCannotTouchOrRemoveReplacement() throws {
        let participants = VideoParticipants()
        let participant = self.makeParticipant()
        let registration = try participants.register(participant)
        registration.invalidate()
        var touched = false
        registration.withParticipant { _ in
            touched = true
        }
        let replacement = self.makeParticipant()
        let replacementRegistration = try participants.register(replacement)

        registration.remove()

        #expect(!touched)
        #expect(participants.participants.compactMap(\.value).first === replacement)
        _ = replacementRegistration
    }

    @MainActor
    @Test("Test Timestamp Diff", arguments: [Self.now.hostDate.timeIntervalSince1970,
                                             Self.pastTimestamp,
                                             Self.futureTimestamp])
    func testTimestampDiff(timestamp: TimeInterval) async throws {
        let participants = VideoParticipants()
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
                                           participants: participants,
                                           metricsSubmitter: nil,
                                           videoBehaviour: .freeze,
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
                                           activeSpeakerStats: nil,
                                           cleanupTime: 10,
                                           slidingWindowTime: 10,
                                           config: .init(calculateLatency: false,
                                                         qualityHitThreshold: 1))
        let subscription = try await self.makeVideoSubscription(participants: participants)
        try set.addHandler(subscription)
        let details = ObjectReceived(timestamp: timestamp,
                                     when: Self.now,
                                     cached: false,
                                     headers: .init(groupId: 0,
                                                    subgroupId: 0,
                                                    objectId: 0,
                                                    payloadLength: 0,
                                                    status: .available,
                                                    priority: nil,
                                                    ttl: nil),
                                     usable: true,
                                     publishTimestamp: nil)

        set.receivedObject(subscription,
                           details: details)
    }
}

extension AvailableImage: Equatable {
    public static func == (lhs: AvailableImage, rhs: AvailableImage) -> Bool {
        lhs.image == rhs.image
    }
}
