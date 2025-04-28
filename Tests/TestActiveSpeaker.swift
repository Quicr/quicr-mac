// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
import OrderedCollections
@testable import QuicR

final class TestActiveSpeaker: XCTestCase {
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
                           ourself: ParticipantId) async throws {
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
        var subbed: [QSubscribeTrackHandlerObjC] = []
        var unsubbed: [QSubscribeTrackHandlerObjC] = []
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

        // Subscribe to 1 and 2.
        if ourself != manifestSubscription1.participantId {
            _ = try controller.subscribeToSet(details: manifestSubscription1, factory: TestCallController.MockSubscriptionFactory({
                XCTAssertEqual($0.sourceId, manifestSubscription1.sourceID)
            }), subscribe: true)
        }
        _ = try controller.subscribeToSet(details: manifestSubscription2, factory: TestCallController.MockSubscriptionFactory({
            XCTAssertEqual($0.sourceId, manifestSubscription2.sourceID)
        }), subscribe: true)

        // 1 and 2 should be created and subscribed to.
        let initialSubscriptionSets = controller.getSubscriptionSets()
        let expected: [ManifestSubscription]
        if ourself == manifestSubscription1.participantId {
            expected = [manifestSubscription2]
        } else {
            expected = [manifestSubscription1, manifestSubscription2]
        }
        XCTAssertEqual(initialSubscriptionSets.map { $0.sourceId }.sorted(), expected.map { $0.sourceID }.sorted())
        let handlers = initialSubscriptionSets.reduce(into: []) { $0.append(contentsOf: $1.getHandlers().values) }
        XCTAssertEqual(handlers.sorted(by: {
            let aFtn = FullTrackName($0.getFullTrackName())
            let bFtn = FullTrackName($1.getFullTrackName())
            guard let lhs = String(data: Data(aFtn.nameSpace.joined()), encoding: .utf8),
                  let rhs = String(data: Data(bFtn.nameSpace.joined()), encoding: .utf8) else {
                return false
            }
            return lhs < rhs
        }), subbed)

        // Now, 1 and 3 are actively speaking.
        subbed = []
        unsubbed = []
        let speakerOne = ParticipantId(1)
        let speakerTwo = ParticipantId(2)
        let speakerThree = ParticipantId(3)
        let newSpeakers: OrderedSet<ParticipantId> = [speakerOne, speakerThree]
        let notifier = MockActiveSpeakerNotifier()
        var created: [SubscriptionSet] = []
        let factory = TestCallController.MockSubscriptionFactory { created.append($0) }
        let activeSpeakerController = try ActiveSpeakerApply<TestCallController.MockSubscription>(notifier: notifier,
                                                                                                  controller: controller,
                                                                                                  videoSubscriptions: manifestSubscriptions,
                                                                                                  factory: factory,
                                                                                                  participantId: ourself,
                                                                                                  activeSpeakerStats: nil)

        // Test state clear.
        XCTAssert(created.isEmpty)
        XCTAssert(subbed.isEmpty)
        XCTAssert(unsubbed.isEmpty)

        // Mock active speaker change.
        if let clamp = clamp {
            activeSpeakerController.setClampCount(clamp)
        }
        notifier.fire(newSpeakers)

        switch clamp {
        case nil:
            // Factory should have created subscription 3.
            XCTAssertEqual(created.map { $0.sourceId }.sorted(), [manifestSubscription3].map { $0.sourceID }.sorted())
            // Controller should have subscribed to 3.
            XCTAssert(subbed.reduce(into: true, {
                $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerThree
            }))
            // Should have unsubscribed from 2 regardless of clamping.
            XCTAssert(unsubbed.reduce(into: true, {
                $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerTwo
            }))
        case 1:
            if ourself == speakerOne {
                // In this case, 3 should be considered, because the top speaker is us (1).
                XCTAssertEqual(created.map { $0.sourceId }.sorted(), [manifestSubscription3].map { $0.sourceID }.sorted())
                XCTAssert(subbed.reduce(into: true, {
                    $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerThree
                }))
            } else {
                // Subscription 3 shouldn't be considered because of the clamping, only 1.
                XCTAssertEqual(created.map { $0.sourceId }, [])
                XCTAssertEqual(subbed.map { FullTrackName($0.getFullTrackName()) }, [])
            }
            // Should have unsubscribed from 2 regardless of clamping or our identity.
            XCTAssert(unsubbed.reduce(into: true, {
                $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerTwo
            }))
        case 10:
            // Factory should have created subscription 3.
            XCTAssertEqual(created.map { $0.sourceId }.sorted(), [manifestSubscription3].map { $0.sourceID }.sorted())
            // Controller should have subscribed to 3.
            XCTAssert(subbed.reduce(into: true, {
                $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerThree
            }))
            // Should NOT have unsubscribed from 2 because we're expanding out to previous due to clamp > speakers.count.
            XCTAssert(unsubbed.isEmpty)
        default:
            XCTFail("Unhandled case")
        }

        // 1 should still be present regardless of clamping, as long as it isn't us.
        if ourself != speakerOne {
            let active = try controller.getSubscriptionsByParticipant(speakerOne)
            XCTAssertEqual(active.count, 1)
            XCTAssertEqual(active[0].participantId, speakerOne)
        }
    }

    func testActiveSpeaker() async throws {
        try await self.testActiveSpeaker(clamp: nil, ourself: .init(4))
    }

    func testActiveSpeakerClamped() async throws {
        try await self.testActiveSpeaker(clamp: 1, ourself: .init(4))
    }

    func testActiveSpeakerExpanded() async throws {
        try await self.testActiveSpeaker(clamp: 10, ourself: .init(4))
    }

    func testIgnoreOurselves() async throws {
        try await self.testActiveSpeaker(clamp: 1, ourself: .init(1))
    }
}
