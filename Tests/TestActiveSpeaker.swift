// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestActiveSpeaker: XCTestCase {
    class MockActiveSpeakerNotifier: ActiveSpeakerNotifier {
        private var callbacks: [CallbackToken: ActiveSpeakersChanged] = [:]
        private var token: CallbackToken = 0

        func fire(_ activeSpeakers: [ParticipantId]) {
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

    func testActiveSpeaker(clamp: Bool) async throws {
        // Given a list of active speakers, the controller's subscriptions should change
        // to reflect the list.

        // Prepare the manifest.
        let manifestSubscription1 = ManifestSubscription(mediaType: "1",
                                                         sourceName: "1",
                                                         sourceID: "1",
                                                         participantId: .init(1),
                                                         label: "1",
                                                         profileSet: .init(type: "1", profiles: [
                                                            .init(qualityProfile: "1",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: ["1"])
                                                         ]))
        let manifestSubscription2 = ManifestSubscription(mediaType: "2",
                                                         sourceName: "2",
                                                         sourceID: "2",
                                                         participantId: .init(2),
                                                         label: "2",
                                                         profileSet: .init(type: "2", profiles: [
                                                            .init(qualityProfile: "2",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: ["2"])
                                                         ]))
        let manifestSubscription3 = ManifestSubscription(mediaType: "3",
                                                         sourceName: "3",
                                                         sourceID: "3",
                                                         participantId: .init(3),
                                                         label: "3",
                                                         profileSet: .init(type: "3", profiles: [
                                                            .init(qualityProfile: "3",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: ["3"])
                                                         ]))
        let manifestSubscriptions = [manifestSubscription1, manifestSubscription2, manifestSubscription3]
        var ftnToParticipantId: [FullTrackName: ParticipantId] = [:]
        for subscription in manifestSubscriptions {
            for profile in subscription.profileSet.profiles {
                ftnToParticipantId[try profile.getFullTrackName()] = subscription.participantId
            }
        }
        var subbed: [QSubscribeTrackHandlerObjC] = []
        var unsubbed: [QSubscribeTrackHandlerObjC] = []
        let sub: TestCallController.MockClient.SubscribeTrackCallback = { subbed.append($0) }
        let unsub: TestCallController.MockClient.SubscribeTrackCallback = { unsubbed.append($0) }

        let client = TestCallController.MockClient(publish: { _ in }, unpublish: { _ in }, subscribe: sub, unsubscribe: unsub)
        let controller = MoqCallController(endpointUri: "4", client: client, submitter: nil) { }
        try await controller.connect()

        // Subscribe to 1 and 2.
        _ = try controller.subscribeToSet(details: manifestSubscription1, factory: TestCallController.MockSubscriptionFactory({
            XCTAssertEqual($0.sourceId, manifestSubscription1.sourceID)
        }), subscribe: true)
        _ = try controller.subscribeToSet(details: manifestSubscription2, factory: TestCallController.MockSubscriptionFactory({
            XCTAssertEqual($0.sourceId, manifestSubscription2.sourceID)
        }), subscribe: true)

        // 1 and 2 should be created and subscribed to.
        let initialSubscriptionSets = controller.getSubscriptionSets()
        XCTAssertEqual(initialSubscriptionSets.map { $0.sourceId }.sorted(), [manifestSubscription1, manifestSubscription2].map { $0.sourceID }.sorted())
        let handlers = initialSubscriptionSets.reduce(into: []) { $0.append(contentsOf: $1.getHandlers().values) }
        XCTAssertEqual(handlers.sorted(by: {
            let aFtn = FullTrackName($0.getFullTrackName())
            let bFtn = FullTrackName($1.getFullTrackName())
            guard let a = String(data: Data(aFtn.nameSpace.joined()), encoding: .utf8),
                  let b = String(data: Data(bFtn.nameSpace.joined()), encoding: .utf8) else {
                return false
            }
            return a < b
        }), subbed)

        // Now, 1 and 3 are actively speaking.
        subbed = []
        unsubbed = []
        let speakerOne = ParticipantId(1)
        let speakerTwo = ParticipantId(2)
        let speakerThree = ParticipantId(3)
        let newSpeakers: [ParticipantId] = [speakerOne, speakerThree]
        let notifier = MockActiveSpeakerNotifier()
        var created: [SubscriptionSet] = []
        let factory = TestCallController.MockSubscriptionFactory { created.append($0) }
        let activeSpeakerController = ActiveSpeakerApply(notifier: notifier,
                                                         controller: controller,
                                                         subscriptions: manifestSubscriptions,
                                                         factory: factory,
                                                         codecFactory: MockCodecFactory())

        // Test state clear.
        XCTAssert(created.isEmpty)
        XCTAssert(subbed.isEmpty)
        XCTAssert(unsubbed.isEmpty)

        // Mock active speaker change.
        if clamp {
            activeSpeakerController.setClampCount(1)
        }
        notifier.fire(newSpeakers)

        if !clamp {
            // Factory should have created subscription 3.
            XCTAssertEqual(created.map { $0.sourceId }.sorted(), [manifestSubscription3].map { $0.sourceID }.sorted())
            // Controller should have subscribed to 3.
            XCTAssert(subbed.reduce(into: true, {
                $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerThree
            }))
        } else {
            // Subscription 3 shouldn't be considered because of the clamping.
            XCTAssertEqual(created.map { $0.sourceId }, [])
            XCTAssertEqual(subbed.map { FullTrackName($0.getFullTrackName()) }, [])
        }
        // Should have unsubscribed from 2 regardless of clamping.
        XCTAssert(unsubbed.reduce(into: true, {
            $0 = $0 && ftnToParticipantId[.init($1.getFullTrackName())] == speakerTwo
        }))
        // 1 should still be present regardless of clamping.
        let active = try controller.getSubscriptionsByParticipant(speakerOne)
        XCTAssert(active.count == 1)
    }

    func testActiveSpeaker() async throws {
        try await self.testActiveSpeaker(clamp: false)
    }

    func testActiveSpeakerClamped() async throws {
        try await self.testActiveSpeaker(clamp: true)
    }
}
