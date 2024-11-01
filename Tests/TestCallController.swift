// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestCallController: XCTestCase {

    class MockPublicationFactory: PublicationFactory {
        typealias PublicationCreated = (Publication) -> Void
        private let callback: PublicationCreated

        init(_ created: @escaping PublicationCreated) {
            self.callback = created
        }

        func create(publication: QuicR.ManifestPublication, endpointId: String, relayId: String) throws -> [(FullTrackName, QPublishTrackHandlerObjC)] {
            var pubs: [(FullTrackName, QPublishTrackHandlerObjC)] = []
            for profile in publication.profileSet.profiles {
                let ftn = try FullTrackName(namespace: profile.namespace, name: "")
                let publication = try MockPublication(profile: profile,
                                                      trackMode: .streamPerGroup,
                                                      defaultPriority: 0,
                                                      defaultTTL: 0,
                                                      submitter: nil,
                                                      endpointId: "",
                                                      relayId: "")
                self.callback(publication)
                pubs.append((ftn, publication))
            }
            return pubs
        }
    }

    class MockPublication: Publication { }

    class MockSubscription: QSubscribeTrackHandlerObjC {
        private let ftn: FullTrackName
        init(ftn: FullTrackName) {
            self.ftn = ftn
            super.init(fullTrackName: self.ftn.getUnsafe())
        }
    }

    class MockSubscriptionSet: SubscriptionSet {
        private let subscription: ManifestSubscription

        init(_ subscription: ManifestSubscription) {
            self.subscription = subscription
        }

        func getHandlers() -> [FullTrackName: QSubscribeTrackHandlerObjC] {
            var subs: [FullTrackName: QSubscribeTrackHandlerObjC] = [:]
            for profile in self.subscription.profileSet.profiles {
                let ftn = try! FullTrackName(namespace: profile.namespace, name: "")
                subs[ftn] = MockSubscription(ftn: ftn)
            }
            return subs
        }
    }

    class MockSubscriptionFactory: SubscriptionFactory {
        func create(subscription: ManifestSubscription, endpointId: String, relayId: String) throws -> any SubscriptionSet {
            return MockSubscriptionSet(subscription)
        }
    }

    class MockClient: MoqClient {
        typealias PublishTrackCallback = (QPublishTrackHandlerObjC) -> Void
        typealias UnpublishTrackCallback = (QPublishTrackHandlerObjC) -> Void
        typealias SubscribeTrackCallback = (QSubscribeTrackHandlerObjC) -> Void
        typealias UnsubscribeTrackCallback = (QSubscribeTrackHandlerObjC) -> Void
        private let publish: PublishTrackCallback
        private let unpublish: UnpublishTrackCallback
        private let subscribe: SubscribeTrackCallback
        private let unsubscribe: UnsubscribeTrackCallback

        init(publish: @escaping PublishTrackCallback,
             unpublish: @escaping UnpublishTrackCallback,
             subscribe: @escaping SubscribeTrackCallback,
             unsubscribe: @escaping UnsubscribeTrackCallback) {
            self.publish = publish
            self.unpublish = unpublish
            self.subscribe = subscribe
            self.unsubscribe = unsubscribe
        }

        func connect() -> QClientStatus {
            .ready
        }

        func disconnect() -> QClientStatus {
            .disconnecting
        }

        func publishTrack(withHandler handler: QPublishTrackHandlerObjC) {
            self.publish(handler)
        }

        func unpublishTrack(withHandler handler: QPublishTrackHandlerObjC) {
            self.unpublish(handler)
        }

        func publishAnnounce(_ trackNamespace: Data) { }
        func publishUnannounce(_ trackNamespace: Data) {}
        func setCallbacks(_ callbacks: any QClientCallbacks) { }

        func subscribeTrack(withHandler handler: QSubscribeTrackHandlerObjC) {
            self.subscribe(handler)
        }

        func unsubscribeTrack(withHandler handler: QSubscribeTrackHandlerObjC) {
            self.unsubscribe(handler)
        }

        func getAnnounceStatus(_ trackNamespace: Data) -> QPublishAnnounceStatus {
            .OK
        }
    }

    func testPublicationAdd() async throws {

        // Example publication details.
        let details = ManifestPublication(mediaType: "video",
                                          sourceName: "test",
                                          sourceID: "test",
                                          label: "Label",
                                          profileSet: .init(type: "type",
                                                            profiles: [
                                                                .init(qualityProfile: "something",
                                                                      expiry: nil,
                                                                      priorities: nil,
                                                                      namespace: "namespace")]))

        var factoryCreated: Publication?
        let creationCallback: MockPublicationFactory.PublicationCreated = { factoryCreated = $0 }

        // Create controller.
        var published = false
        let publish: MockClient.PublishTrackCallback = {
            published = $0 == factoryCreated
        }
        let unpublished: MockClient.UnpublishTrackCallback = { _ in }
        let subscribe: MockClient.SubscribeTrackCallback = { _ in }
        let unsubscribe: MockClient.UnsubscribeTrackCallback = { _ in }
        let client = MockClient(publish: publish, unpublish: unpublished, subscribe: subscribe, unsubscribe: unsubscribe)
        let controller = MoqCallController(endpointUri: "1", client: client, submitter: nil) { }
        try await controller.connect()

        // Calling publish should result in a matching publication being created from the factory, and a publish track being issued on it.
        try controller.publish(details: details, factory: MockPublicationFactory(creationCallback))
        XCTAssert(published)
    }

    func testMetrics() throws {
        //        let config = ClientConfig(connectUri: "moq://localhost",
        //                                  endpointUri: "me",
        //                                  transportConfig: .init(),
        //                                  metricsSampleMs: 0)
        //        let controller = MoqCallController(config: config,
        //                                           captureManager: try .init(metricsSubmitter: nil,
        //                                                                     granularMetrics: false),
        //                                           subscriptionConfig: .init(),
        //                                           engine: try .init(),
        //                                           videoParticipants: .init(),
        //                                           submitter: nil,
        //                                           granularMetrics: false,
        //                                           callEnded: {})
        //        controller.metricsSampled(.init())
    }
}
