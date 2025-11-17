// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Testing
import OrderedCollections
@testable import QuicR

struct TestActiveSpeaker {
    class MockVideoSubscriptionFactory: TestCallController.GenericMockSubscriptionFactory<VideoSubscriptionSet, TestCallController.MockSubscription> {
        var participants: VideoParticipants?
        override init(_ callback: @escaping SubscriptionCreated) {
            super.init(callback)
            DispatchQueue.main.sync {
                self.participants = .init()
            }
        }

        override func make(subscription: ManifestSubscription,
                           codecFactory: any CodecFactory,
                           endpointId: String,
                           relayId: String) throws -> VideoSubscriptionSet {
            return try .init(subscription: subscription,
                             participants: self.participants!,
                             metricsSubmitter: nil,
                             videoBehaviour: .freeze,
                             reliable: true,
                             granularMetrics: true,
                             jitterBufferConfig: .init(),
                             simulreceive: .enable,
                             qualityMissThreshold: 30,
                             pauseMissThreshold: 30,
                             pauseResume: false,
                             endpointId: endpointId,
                             relayId: relayId,
                             codecFactory: MockCodecFactory(),
                             joinDate: .now,
                             activeSpeakerStats: nil,
                             cleanupTime: 30,
                             slidingWindowTime: 30,
                             config: .init(calculateLatency: false,
                                           qualityHitThreshold: 3))
        }

        override func make(set: VideoSubscriptionSet,
                           profile: Profile,
                           codecFactory: any CodecFactory,
                           endpointId: String,
                           relayId: String) throws -> TestCallController.MockSubscription {
            try TestCallController.MockSubscription(profile: profile)
        }
    }

    class MockOtherSubscriptionFactory: TestCallController.GenericMockSubscriptionFactory<ObservableSubscriptionSet, TestCallController.MockSubscription> {
        override func make(subscription: ManifestSubscription,
                           codecFactory: any CodecFactory,
                           endpointId: String,
                           relayId: String) throws -> ObservableSubscriptionSet {
            .init(sourceId: subscription.sourceID, participantId: subscription.participantId)
        }

        override func make(set: ObservableSubscriptionSet,
                           profile: Profile,
                           codecFactory: any CodecFactory,
                           endpointId: String,
                           relayId: String) throws -> TestCallController.MockSubscription {
            try TestCallController.MockSubscription(profile: profile)
        }
    }

    class MockActiveSpeakerNotifier: ActiveSpeakerNotifier {
        private var callbacks: [CallbackToken: ActiveSpeakersChanged] = [:]
        private var token: CallbackToken = 0

        func fire(_ activeSpeakers: OrderedSet<ParticipantId>) {
            for callback in self.callbacks.values {
                callback(activeSpeakers)
            }
        }

        func registerActiveSpeakerCallback(_ callback: @escaping ActiveSpeakersChanged) -> CallbackToken {
            let token = self.token
            self.token += 1
            self.callbacks[token] = callback
            return token
        }

        func unregisterActiveSpeakerCallback(_ token: CallbackToken) {
            self.callbacks.removeValue(forKey: token)
        }
    }

    func testActiveSpeaker(clamp: Int?, // swiftlint:disable:this function_body_length
                           ourself: ParticipantId,
                           pauseResume: Bool) async throws {
        // Given a list of active speakers, the controller's subscriptions should change
        // to reflect the list.

        // Prepare the manifest.
        let manifestSubscription1 = ManifestSubscription(mediaType: ManifestMediaTypes.video.rawValue,
                                                         sourceName: "1",
                                                         sourceID: "1",
                                                         label: "1",
                                                         participantId: .init(1),
                                                         profileSet: .init(type: "1", profiles: [
                                                            .init(qualityProfile: "1",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: ["1"])
                                                         ]))
        let manifestSubscription2 = ManifestSubscription(mediaType: ManifestMediaTypes.video.rawValue,
                                                         sourceName: "2",
                                                         sourceID: "2",
                                                         label: "2",
                                                         participantId: .init(2),
                                                         profileSet: .init(type: "2", profiles: [
                                                            .init(qualityProfile: "2",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: ["2"])
                                                         ]))
        let manifestSubscription3 = ManifestSubscription(mediaType: ManifestMediaTypes.video.rawValue,
                                                         sourceName: "3",
                                                         sourceID: "3",
                                                         label: "3",
                                                         participantId: .init(3),
                                                         profileSet: .init(type: "3", profiles: [
                                                            .init(qualityProfile: "3",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: ["3"])
                                                         ]))
        let manifestSubscriptions: [ManifestSubscription]
        if ourself == manifestSubscription1.participantId {
            manifestSubscriptions = [manifestSubscription2, manifestSubscription3]
        } else {
            manifestSubscriptions = [manifestSubscription1, manifestSubscription2, manifestSubscription3]
        }
        var ftnToParticipantId: [FullTrackName: ParticipantId] = [:]
        for subscription in manifestSubscriptions {
            for profile in subscription.profileSet.profiles {
                ftnToParticipantId[try profile.getFullTrackName()] = subscription.participantId
            }
        }
        var subbed: [Subscription] = []
        var unsubbed: [Subscription] = []
        let sub: MockClient.SubscribeTrackCallback = { subbed.append($0) }
        let unsub: MockClient.SubscribeTrackCallback = { unsubbed.append($0) }

        let client = MockClient(publish: { _ in },
                                unpublish: { _ in },
                                subscribe: sub,
                                unsubscribe: unsub,
                                fetch: { _ in },
                                fetchCancel: { _ in })
        let controller = MoqCallController(endpointUri: "4", client: client, submitter: nil) { }
        try await controller.connect()

        // Subscribe to something that isn't a video subscription, to ensure we don't
        // alter the behaviour of non-video subscriptions.
        let manifestSubscriptionOther = ManifestSubscription(mediaType: "",
                                                             sourceName: "",
                                                             sourceID: "nonvideo",
                                                             label: "",
                                                             participantId: .init(0),
                                                             profileSet: .init(type: "other", profiles: [
                                                                .init(qualityProfile: "",
                                                                      expiry: nil,
                                                                      priorities: nil,
                                                                      namespace: ["not", "video"])
                                                             ]))
        var nonVideoSet = try controller.subscribeToSet(details: manifestSubscriptionOther,
                                                        factory: MockOtherSubscriptionFactory({ _ in}),
                                                        subscribeType: .subscribe)

        // Subscribe to 1 and 2.
        var setOne: VideoSubscriptionSet?
        if ourself != manifestSubscription1.participantId {
            setOne = try controller.subscribeToSet(details: manifestSubscription1,
                                                   factory: MockVideoSubscriptionFactory({
                                                    #expect($0.sourceId == manifestSubscription1.sourceID)
                                                   }), subscribeType: .subscribe) as! VideoSubscriptionSet? // swiftlint:disable:this force_cast
        }
        let setTwo = try controller.subscribeToSet(details: manifestSubscription2,
                                                   factory: MockVideoSubscriptionFactory({
                                                    #expect($0.sourceId == manifestSubscription2.sourceID)
                                                   }), subscribeType: .subscribe) as! VideoSubscriptionSet // swiftlint:disable:this force_cast

        // 1 and 2 should be created and subscribed to.
        let initialSubscriptionSets = controller.getSubscriptionSets()
        let expected: [ManifestSubscription]
        if ourself == manifestSubscription1.participantId {
            expected = [manifestSubscriptionOther, manifestSubscription2]
        } else {
            expected = [manifestSubscriptionOther, manifestSubscription1, manifestSubscription2]
        }
        #expect(initialSubscriptionSets.map { $0.sourceId }.sorted() == expected.map { $0.sourceID }.sorted())
        let handlers = initialSubscriptionSets.reduce(into: []) { $0.append(contentsOf: $1.getHandlers().values) }
        let sortedHandlers = handlers.sorted(by: {
            let aFtn = FullTrackName($0.getFullTrackName())
            let bFtn = FullTrackName($1.getFullTrackName())
            guard let lhs = String(data: Data(aFtn.nameSpace.joined()), encoding: .utf8),
                  let rhs = String(data: Data(bFtn.nameSpace.joined()), encoding: .utf8) else {
                return false
            }
            return lhs < rhs
        })
        #expect(Set(handlers) == Set(subbed))

        // Mark 1 and 2 as in displaying state.
        if let setOne {
            setOne.fireDisplayCallbacks()
        }
        setTwo.fireDisplayCallbacks()

        // Now, 1 and 3 are actively speaking.
        subbed = []
        unsubbed = []
        let speakerOne = ParticipantId(1)
        let speakerTwo = ParticipantId(2)
        let speakerThree = ParticipantId(3)
        let newSpeakers: OrderedSet<ParticipantId> = [speakerOne, speakerThree]
        let notifier = MockActiveSpeakerNotifier()
        var created: [SubscriptionSet] = []
        let factory = MockVideoSubscriptionFactory { created.append($0) }
        let activeSpeakerController: ActiveSpeakerApply<TestCallController.MockSubscription>
        activeSpeakerController = try .init(notifier: notifier,
                                            controller: controller,
                                            videoSubscriptions: manifestSubscriptions,
                                            factory: factory,
                                            participantId: ourself,
                                            activeSpeakerStats: nil,
                                            pauseResume: pauseResume)

        // Test state clear.
        #expect(created.isEmpty)
        #expect(subbed.isEmpty)
        #expect(unsubbed.isEmpty)

        // Mock active speaker change.
        if let clamp = clamp {
            activeSpeakerController.setClampCount(clamp)
        }
        notifier.fire(newSpeakers)

        switch clamp {
        case nil:
            // In this case, there is no clamping. Our response should
            // match the received active speaker list exactly.
            // 1 and 2 were speaking, now 1 and 3 are.
            // Excpect a subscribe/resume to 3, and a unsubscribe/pause to 2.

            // Factory should have created subscription 3.
            #expect(created.count == 1)
            #expect(created.map { $0.sourceId }.sorted() == [manifestSubscription3].map { $0.sourceID }.sorted())
            #expect(created.allSatisfy { !$0.isPaused })
            // Controller should have subscribed to 3.
            #expect(subbed.count == 1)
            #expect(subbed.allSatisfy { ftnToParticipantId[.init($0.getFullTrackName())] == speakerThree })
            #expect(subbed.allSatisfy { !$0.isPaused })

            // We won't yet have unsubscribed/paused from non-active speaker 2,
            // until we have a frame to display from new speaker 3.
            #expect(unsubbed.count == 0)
            if pauseResume {
                #expect(!setTwo.isPaused)
            }

            // Mock a frame displaying from 3.
            let three = created[0] as! VideoSubscriptionSet // swiftlint:disable:this force_cast
            three.fireDisplayCallbacks()

            if pauseResume {
                // Should now have paused 2.
                #expect(setTwo.isPaused)
                #expect(unsubbed.count == 0)
            } else {
                // Should now have unsubscribed from 2.
                #expect(unsubbed.count == 1)
                #expect(unsubbed.allSatisfy { ftnToParticipantId[.init($0.getFullTrackName())] == speakerTwo })
            }
        case 1:
            // We're only showing one participant. 1 and 2 were speaking, now 1 and 3.
            if ourself == speakerOne {
                // In this case, the top active speaker is us, so the next (3) should be subscribed.
                #expect(created.map { $0.sourceId }.sorted() == [manifestSubscription3].map { $0.sourceID }.sorted())
                #expect(created.allSatisfy { !$0.isPaused })
                #expect(subbed.count == 1)
                #expect(subbed.allSatisfy { ftnToParticipantId[.init($0.getFullTrackName())] == speakerThree })
                #expect(subbed.allSatisfy { !$0.isPaused })

                // 2 should not yet be unsubscribed/paused until we get a frame from 3.
                #expect(unsubbed.count == 0)
                #expect(!setTwo.isPaused)

                // Mock a frame displaying from 3.
                let three = created[0] as! VideoSubscriptionSet // swiftlint:disable:this force_cast
                three.fireDisplayCallbacks()

                // Now 2 should have gone away.
                if pauseResume {
                    #expect(setTwo.isPaused)
                    #expect(unsubbed.count == 0)
                } else {
                    #expect(unsubbed.count == 1)
                    #expect(unsubbed.allSatisfy { ftnToParticipantId[.init($0.getFullTrackName())] == speakerTwo })
                }
            } else {
                // Subscription 3 shouldn't be subscribed because of the clamping, only 1 (which already exists).
                if pauseResume {
                    #expect(created.count == 0)
                } else {
                    #expect(created.map { $0.sourceId } == [])
                    #expect(subbed.map { FullTrackName($0.getFullTrackName()) } == [])
                }

                // In this case, 1 is already displaying, so 2 should immediately be unsubscribed/paused.
                if pauseResume {
                    #expect(setTwo.isPaused)
                    #expect(unsubbed.count == 0)
                } else {
                    #expect(unsubbed.count == 1)
                    #expect(unsubbed.allSatisfy { ftnToParticipantId[.init($0.getFullTrackName())] == speakerTwo })
                }
            }
        case 10:
            // Factory should have created subscription for new speaker 3.
            #expect(created.count == 1)
            #expect(created.map { $0.sourceId }.sorted() == [manifestSubscription3].map { $0.sourceID }.sorted())
            #expect(created.allSatisfy { !$0.isPaused })
            // Controller should have subscribed to new speaker 3.
            #expect(subbed.count == 1)
            #expect(subbed.allSatisfy { ftnToParticipantId[.init($0.getFullTrackName())] == speakerThree })
            #expect(subbed.allSatisfy { !$0.isPaused })
            // Should NOT have unsubscribed from 2 because we're
            // expanding out to previous due to clamp > speakers.count.
            #expect(unsubbed.isEmpty)
            #expect(!setTwo.isPaused)

            // Even if a frame arrives from 3.
            let three = created[0] as! VideoSubscriptionSet // swiftlint:disable:this force_cast
            three.fireDisplayCallbacks()
            #expect(unsubbed.isEmpty)
            #expect(!setTwo.isPaused)
        default:
            Issue.record("Unhandled case")
        }

        // 1 should still be present regardless of clamping, as long as it isn't us.
        if ourself != speakerOne {
            let active = try controller.getSubscriptionsByParticipant(speakerOne)
            #expect(active.count == 1)
            #expect(active[0].participantId == speakerOne)
            #expect(!active[0].isPaused)
        }
    }

    @Test("Active speaker handling", arguments: [nil, 1, 10], [true, false])
    func testActiveSpeaker(clamp: Int?, pauseResume: Bool) async throws {
        try await self.testActiveSpeaker(clamp: clamp, ourself: .init(4), pauseResume: pauseResume)
    }

    @Test("Active speaker ignoring ourselves", arguments: [true, false])
    func testIgnoreOurselves(_ pauseResume: Bool) async throws {
        try await self.testActiveSpeaker(clamp: 1, ourself: .init(1), pauseResume: pauseResume)
    }
}
