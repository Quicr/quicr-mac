// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestActiveSpeaker: XCTestCase {
    class MockActiveSpeakerNotifier: ActiveSpeakerNotifier {
        private var callbacks: [CallbackToken: ActiveSpeakersChanged] = [:]
        private var token: CallbackToken = 0

        func fire(_ activeSpeakers: [EndpointId]) {
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

    func testActiveSpeaker() async throws {
        // Given a list of active speakers, the controller's subscriptions should change
        // to reflect the list.

        // Prepare the manifest.
        func makeVideoNamespace(_ endpointId: Int) -> String {
            "0x000001010003F2A0000\(endpointId)000000000000/80"
        }
        let manifestSubscription1 = ManifestSubscription(mediaType: "1",
                                                         sourceName: "1",
                                                         sourceID: "1",
                                                         label: "1",
                                                         profileSet: .init(type: "1", profiles: [
                                                            .init(qualityProfile: "1",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: makeVideoNamespace(1))
                                                         ]))
        let manifestSubscription2 = ManifestSubscription(mediaType: "2",
                                                         sourceName: "2",
                                                         sourceID: "2",
                                                         label: "2",
                                                         profileSet: .init(type: "2", profiles: [
                                                            .init(qualityProfile: "2",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: makeVideoNamespace(2))
                                                         ]))
        let manifestSubscription3 = ManifestSubscription(mediaType: "3",
                                                         sourceName: "3",
                                                         sourceID: "3",
                                                         label: "3",
                                                         profileSet: .init(type: "3", profiles: [
                                                            .init(qualityProfile: "3",
                                                                  expiry: nil,
                                                                  priorities: nil,
                                                                  namespace: makeVideoNamespace(3))
                                                         ]))
        let manifestSubscriptions = [manifestSubscription1, manifestSubscription2, manifestSubscription3]

        var subbed: [QSubscribeTrackHandlerObjC] = []
        var unsubbed: [QSubscribeTrackHandlerObjC] = []
        let sub: TestCallController.MockClient.SubscribeTrackCallback = { subbed.append($0) }
        let unsub: TestCallController.MockClient.SubscribeTrackCallback = { unsubbed.append($0) }

        let client = TestCallController.MockClient(publish: { _ in }, unpublish: { _ in }, subscribe: sub, unsubscribe: unsub)
        let controller = MoqCallController(endpointUri: "4", client: client, submitter: nil) { }
        try await controller.connect()

        // Subscribe to 1 and 2.
        try controller.subscribeToSet(details: manifestSubscription1, factory: TestCallController.MockSubscriptionFactory({
            XCTAssertEqual($0.sourceId, manifestSubscription1.sourceID)
        }))
        try controller.subscribeToSet(details: manifestSubscription2, factory: TestCallController.MockSubscriptionFactory({
            XCTAssertEqual($0.sourceId, manifestSubscription2.sourceID)
        }))

        // 1 and 2 should be created and subscribed to.
        let initialSubscriptionSets = controller.getSubscriptionSets()
        XCTAssertEqual(initialSubscriptionSets.map { $0.sourceId }.sorted(), [manifestSubscription1, manifestSubscription2].map { $0.sourceID }.sorted())
        let handlers = initialSubscriptionSets.reduce(into: []) { $0.append(contentsOf: $1.getHandlers().values) }
        XCTAssertEqual(try handlers.sorted(by: {
            try FullTrackName($0.getFullTrackName()).getNamespace() < FullTrackName($1.getFullTrackName()).getNamespace()
        }), subbed)

        // Now, 1 and 3 are actively speaking.
        subbed = []
        unsubbed = []
        let speakerOne: EndpointId = "0001"
        let speakerTwo: EndpointId = "0002"
        let speakerThree: EndpointId = "0003"
        let newSpeakers: [EndpointId] = [speakerOne, speakerThree]
        let notifier = MockActiveSpeakerNotifier()
        var created: [SubscriptionSet] = []
        let factory = TestCallController.MockSubscriptionFactory { created.append($0) }
        let activeSpeakerController = ActiveSpeakerApply(notifier: notifier,
                                                         controller: controller,
                                                         subscriptions: manifestSubscriptions,
                                                         factory: factory)

        // Test state clear.
        XCTAssert(created.isEmpty)
        XCTAssert(subbed.isEmpty)
        XCTAssert(unsubbed.isEmpty)

        // Mock active speaker change.
        notifier.fire(newSpeakers)

        // Factory should have created subscription 3.
        XCTAssertEqual(created.map { $0.sourceId }.sorted(), [manifestSubscription3].map { $0.sourceID }.sorted())
        // Controller should have subscribed to 3.
        XCTAssert(try subbed.reduce(into: true, {
            try $0 = $0 && FullTrackName($1.getFullTrackName()).getEndpointId() == speakerThree
        }))
        // Should have unsubscribed from 2.
        XCTAssert(try unsubbed.reduce(into: true, {
            try $0 = $0 && FullTrackName($1.getFullTrackName()).getEndpointId() == speakerTwo
        }))
        // 1 should still be present.
        let active = try controller.getSubscriptionsByEndpoint(speakerOne)
        XCTAssert(active.count == 1)
    }
}
