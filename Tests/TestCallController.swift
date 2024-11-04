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
    
    class MockSubscriptionFactory: SubscriptionFactory {
        typealias SubscriptionCreated = (SubscriptionSet) -> Void
        private let callback: SubscriptionCreated

        init(_ callback: @escaping SubscriptionCreated) {
            self.callback = callback
        }

        func create(subscription: ManifestSubscription, endpointId: String, relayId: String) throws -> any SubscriptionSet {
            let set = MockSubscriptionSet(subscription)
            self.callback(set)
            return set
        }
    }

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

    class MockClient: MoqClient {
        typealias PublishTrackCallback = (QPublishTrackHandlerObjC) -> Void
        typealias UnpublishTrackCallback = (QPublishTrackHandlerObjC) -> Void
        typealias SubscribeTrackCallback = (QSubscribeTrackHandlerObjC) -> Void
        typealias UnsubscribeTrackCallback = (QSubscribeTrackHandlerObjC) -> Void
        private let publish: PublishTrackCallback
        private let unpublish: UnpublishTrackCallback
        private let subscribe: SubscribeTrackCallback
        private let unsubscribe: UnsubscribeTrackCallback
        private var callbacks: QClientCallbacks?

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
            let serverId = "test"
            serverId.withCString {
                self.callbacks!.serverSetupReceived(.init(moqt_version: 1, server_id: $0))
            }
            return .ready
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

        func setCallbacks(_ callbacks: any QClientCallbacks) {
            self.callbacks = callbacks
        }

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

    func testPublicationAlter() async throws {
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
        var unpublished = false
        let publish: MockClient.PublishTrackCallback = {
            published = $0 == factoryCreated
        }
        let unpublish: MockClient.UnpublishTrackCallback = {
            unpublished = $0 == factoryCreated
        }
        let subscribe: MockClient.SubscribeTrackCallback = { _ in }
        let unsubscribe: MockClient.UnsubscribeTrackCallback = { _ in }
        let client = MockClient(publish: publish, unpublish: unpublish, subscribe: subscribe, unsubscribe: unsubscribe)
        let controller = MoqCallController(endpointUri: "1", client: client, submitter: nil) { }
        try await controller.connect()

        // Calling publish should result in a matching publication being created from the factory, and a publish track being issued on it.
        try controller.publish(details: details, factory: MockPublicationFactory(creationCallback))
        XCTAssert(published)
        
        // This publication should show as tracked.
        var publications = controller.getPublications()
        let namespace = details.profileSet.profiles.first!.namespace
        let ftn = try FullTrackName(namespace: namespace, name: "")
        XCTAssertEqual(publications, [ftn])
        
        // Removing should unpublish.
        try controller.unpublish(ftn)
        XCTAssert(unpublished)
        
        // No publications should be left.
        publications = controller.getPublications()
        XCTAssertEqual(publications, [])
    }
    
    func testSubscriptionAlter() async throws {
        let sourceID = "TESTING"
        let namespace = "namespace"
        let details = ManifestSubscription(mediaType: "video",
                                           sourceName: "test",
                                           sourceID: "",
                                           label: "testLabel",
                                           profileSet: .init(type: "video",
                                                             profiles: [
                                                                .init(qualityProfile: "h264",
                                                                      expiry: nil,
                                                                      priorities: nil,
                                                                      namespace: "namespace")
                                                             ]))
        
        let expectedFtn: [FullTrackName] = [try .init(namespace: namespace, name: "")]
        var factoryCreated: SubscriptionSet?
        let creationCallback: MockSubscriptionFactory.SubscriptionCreated = {
            factoryCreated = $0
        }
        let factory = MockSubscriptionFactory(creationCallback)
        
        // Create controller.
        let publish: MockClient.PublishTrackCallback = { _ in }
        let unpublish: MockClient.UnpublishTrackCallback = { _ in }
        var subscribed: [FullTrackName] = []
        var unsubscribed: [FullTrackName] = []
        let subscribe: MockClient.SubscribeTrackCallback = {
            subscribed.append(FullTrackName($0.getFullTrackName()))
        }
        let unsubscribe: MockClient.UnsubscribeTrackCallback = {
            unsubscribed.append(FullTrackName($0.getFullTrackName()))
        }
        let client = MockClient(publish: publish, unpublish: unpublish, subscribe: subscribe, unsubscribe: unsubscribe)
        let controller = MoqCallController(endpointUri: "1", client: client, submitter: nil) { }
        try await controller.connect()
        
        // Subscribing to the set should cause a set to be created,
        // and subscribeTrack to be called on all contained subscriptions.
        try controller.subscribeToSet(details: details, factory: factory)
        XCTAssertEqual(subscribed, expectedFtn)
        
        
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
