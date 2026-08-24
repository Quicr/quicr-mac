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

    private func makeAvailableImage(presentationTime: CMTime = .init(value: 1, timescale: 1),
                                    duration: CMTime = .init(seconds: 5, preferredTimescale: 1_000)) throws -> AvailableImage {
        var imageBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         640,
                                         480,
                                         kCMPixelFormat_24RGB,
                                         nil,
                                         &imageBuffer)
        guard result == .zero,
              let imageBuffer else { throw "Failed to create image buffer: \(result)" }
        let format = try CMVideoFormatDescription(imageBuffer: imageBuffer)
        let sample = try CMSampleBuffer(imageBuffer: imageBuffer,
                                        formatDescription: format,
                                        sampleTiming: .init(duration: duration,
                                                            presentationTimeStamp: presentationTime,
                                                            decodeTimeStamp: .invalid))
        return .init(image: sample, fps: 30, discontinous: false)
    }

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
                                       cleanupTime: TimeInterval = 1.5,
                                       statusChanged: VideoSubscription.VideoStatusCallback? = nil,
                                       callback: VideoSubscription.Callback? = nil,
                                       handlerStopped: VideoSubscription.HandlerStoppedCallback? = nil) async throws -> VideoSubscription {
        return try await TestVideoSubscription().makeSubscription(.video(),
                                                                  fetchThreshold: 0,
                                                                  ngThreshold: 0,
                                                                  namespace: namespace,
                                                                  callback: callback,
                                                                  cleanupTime: cleanupTime,
                                                                  participants: participants,
                                                                  simulreceive: .enable,
                                                                  statusChanged: statusChanged,
                                                                  handlerStopped: handlerStopped)
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
    @Test("A sleeping render task does not retain its subscription set")
    func testSleepingRenderTaskDoesNotRetainSet() async throws {
        let participants = VideoParticipants()
        var set: VideoSubscriptionSet? = try self.makeSimulreceiveSet(participants: participants)
        let subscription = try await self.makeVideoSubscription(participants: participants)
        try set!.addHandler(subscription)
        let currentHandler = subscription.handler.get()
        let handler = try #require(currentHandler)
        let image = try self.makeAvailableImage()
        handler.lastDecodedImage.withLock { $0 = image }
        set!.receivedObject(subscription,
                            details: self.makeObjectReceived(timestamp: 1))

        for _ in 0..<1_000 where set?.getMediaState() != .rendered {
            await Task.yield()
        }
        guard set?.getMediaState() == .rendered else {
            Issue.record("Render task did not render the synchronization frame")
            return
        }
        await Task.yield()

        weak var releasedSet = set
        set = nil

        for _ in 0..<100 where releasedSet != nil {
            await Task.yield()
        }

        #expect(releasedSet == nil)
    }

    @MainActor
    @Test("Same-group data promptly restarts rendering after handler cleanup")
    func testSameGroupReactivationRestartsRender() async throws {
        let participants = VideoParticipants()
        let set = try self.makeSimulreceiveSet(participants: participants)
        let displayCount = Mutex(0)
        set.registerDisplayCallback { _ in
            displayCount.withLock { $0 += 1 }
        }
        let subscription = try await self.makeVideoSubscription(
            participants: participants,
            cleanupTime: 0.2,
            handlerStopped: { [weak set] subscription in
                set?.handlerStopped(subscription)
            })
        try set.addHandler(subscription)
        let currentHandler = subscription.handler.get()
        let initialHandler = try #require(currentHandler)

        // Start the real inactivity cleanup without producing a decoded frame.
        subscription.mockObject(groupId: 0, objectId: 0)
        set.receivedObject(subscription,
                           details: self.makeObjectReceived(timestamp: 10))

        for _ in 0..<200 where subscription.handler.get() != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(subscription.handler.get() == nil)
        for _ in 0..<200 where set.getMediaState() != .subscribed {
            await Task.yield()
        }
        #expect(displayCount.get() == 0)
        #expect(set.getMediaState() == .subscribed)

        subscription.mockObject(groupId: 0,
                                objectId: 0,
                                immutableExtensions: .video(sequenceNumber: 2))
        let recreatedHandler = subscription.handler.get()
        let replacement = try #require(recreatedHandler)
        #expect(replacement !== initialHandler)
        let replacementImage = try self.makeAvailableImage(presentationTime: .init(value: 2, timescale: 1),
                                                           duration: .invalid)
        replacement.lastDecodedImage.withLock {
            $0 = replacementImage
        }
        set.receivedObject(subscription,
                           details: self.makeObjectReceived(timestamp: 1))
        for _ in 0..<60 where displayCount.get() == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(displayCount.get() == 1)
        #expect(replacement.timeDiff.getTimeDiff()?.senderTimestamp == 1)
    }

    @MainActor
    @Test("Removing a handler drains its render before reuse")
    func testRemovingHandlerDrainsRenderBeforeReuse() async throws {
        let participants = VideoParticipants()
        let set = try self.makeSimulreceiveSet(participants: participants)
        let displayCount = Mutex(0)
        set.registerDisplayCallback { _ in
            displayCount.withLock { $0 += 1 }
        }
        let subscription = try await self.makeVideoSubscription(participants: participants,
                                                                namespace: ["removed"])
        let remaining = try await self.makeVideoSubscription(participants: participants,
                                                             namespace: ["remaining"])
        try set.addHandler(subscription)
        try set.addHandler(remaining)
        let currentHandler = subscription.handler.get()
        let handler = try #require(currentHandler)
        let image = try self.makeAvailableImage(presentationTime: .init(value: 10, timescale: 1))
        handler.lastDecodedImage.withLock { $0 = image }
        let imageLockHeld = DispatchSemaphore(value: 0)
        let releaseImageLock = DispatchSemaphore(value: 0)
        let lockTask = Task.detached {
            handler.lastDecodedImage.withLock { _ in
                imageLockHeld.signal()
                releaseImageLock.wait()
            }
        }
        let locked = await Task.detached {
            imageLockHeld.wait(timeout: .now() + 2) == .success
        }.value
        guard locked else {
            releaseImageLock.signal()
            await lockTask.value
            Issue.record("Could not lock the old handler image")
            return
        }

        set.receivedObject(subscription,
                           details: self.makeObjectReceived(timestamp: 10))
        for _ in 0..<1_000 {
            await Task.yield()
        }

        let fullTrackName = FullTrackName(subscription.getFullTrackName())
        let removeFinished = DispatchSemaphore(value: 0)
        let removeTask = Task.detached {
            let removed = set.removeHandler(fullTrackName)
            removeFinished.signal()
            return removed
        }
        let removedBeforeDecisionReturned = await Task.detached {
            removeFinished.wait(timeout: .now() + 0.2) == .success
        }.value
        #expect(!removedBeforeDecisionReturned)

        releaseImageLock.signal()
        await lockTask.value
        let removed = await removeTask.value
        #expect(removed === subscription)
        for _ in 0..<100 where displayCount.get() == 0 {
            await Task.yield()
        }
        #expect(displayCount.get() == 0)

        let currentRemainingHandler = remaining.handler.get()
        let remainingHandler = try #require(currentRemainingHandler)
        remainingHandler.lastDecodedImage.withLock { $0 = image }
        set.receivedObject(remaining,
                           details: self.makeObjectReceived(timestamp: 10))
        for _ in 0..<1_000 where displayCount.get() != 1 {
            await Task.yield()
        }
        #expect(displayCount.get() == 1)

        set.receivedObject(remaining,
                           details: self.makeObjectReceived(timestamp: nil))
        let remainingFullTrackName = FullTrackName(remaining.getFullTrackName())
        #expect(set.removeHandler(remainingFullTrackName) === remaining)
        #expect(set.getMediaState() == .subscribed)
        for _ in 0..<20 where !participants.participants.isEmpty {
            await Task.yield()
        }
        #expect(participants.participants.compactMap(\.value).isEmpty)

        let replacement = try await self.makeVideoSubscription(participants: participants,
                                                               namespace: ["remaining"])
        try set.addHandler(replacement)
        let currentReplacementHandler = replacement.handler.get()
        let replacementHandler = try #require(currentReplacementHandler)
        let replacementImage = try self.makeAvailableImage()
        replacementHandler.lastDecodedImage.withLock { $0 = replacementImage }
        set.receivedObject(replacement,
                           details: self.makeObjectReceived(timestamp: 1))
        #expect(replacementHandler.timeDiff.getTimeDiff()?.senderTimestamp == 1)
        for _ in 0..<1_000 where displayCount.get() != 2 {
            await Task.yield()
        }

        #expect(displayCount.get() == 2)
        #expect(set.getMediaState() == .rendered)
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
