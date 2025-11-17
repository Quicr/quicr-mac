// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
import Synchronization
@testable import QuicR

final class TestFullTrackName: XCTestCase {
    /// Test compatbility between Swift and Objective-C representations of ``FullTrackName``.
    func testFullTrackName() throws {
        // QFullTrackName.
        let namespace = "namespace"
        let name = "name"
        let qftn = QFullTrackNameImpl()
        qftn.nameSpace = [namespace.data(using: .utf8)!]
        qftn.name = name.data(using: .utf8)!
        let swift = FullTrackName(qftn as QFullTrackName)
        XCTAssertEqual(swift.name, qftn.name)
        XCTAssertEqual(swift.nameSpace, qftn.nameSpace)
    }
}

final class TestCallController: XCTestCase {

    class MockPublicationFactory: PublicationFactory {
        typealias PublicationCreated = (Publication) -> Void
        private let callback: PublicationCreated

        init(_ created: @escaping PublicationCreated) {
            self.callback = created
        }

        func create(publication: QuicR.ManifestPublication, codecFactory: CodecFactory, endpointId: String, relayId: String) throws -> [(FullTrackName, QPublishTrackHandlerObjC)] {
            var pubs: [(FullTrackName, QPublishTrackHandlerObjC)] = []
            for profile in publication.profileSet.profiles {
                let ftn = try FullTrackName(namespace: profile.namespace, name: "")
                let publication = try MockPublication(profile: profile,
                                                      trackMode: .stream,
                                                      defaultPriority: 0,
                                                      defaultTTL: 0,
                                                      submitter: nil,
                                                      endpointId: "",
                                                      relayId: "",
                                                      logger: DecimusLogger(TestPublication.self),
                                                      useAnnounce: false)
                self.callback(publication)
                pubs.append((ftn, publication))
            }
            return pubs
        }
    }

    class MockPublication: Publication { }

    class MockSubscriptionFactory: GenericMockSubscriptionFactory<ObservableSubscriptionSet, MockSubscription> {
        override func make(subscription: ManifestSubscription,
                           codecFactory: CodecFactory,
                           endpointId: String,
                           relayId: String) throws -> ObservableSubscriptionSet {
            return ObservableSubscriptionSet(sourceId: subscription.sourceID, participantId: subscription.participantId)
        }

        override func make(set: ObservableSubscriptionSet,
                           profile: Profile,
                           codecFactory: any CodecFactory,
                           endpointId: String,
                           relayId: String) throws -> TestCallController.MockSubscription {
            try .init(profile: profile)
        }
    }

    class GenericMockSubscriptionFactory<T: SubscriptionSet, K: Subscription>: SubscriptionFactory {
        typealias SubscriptionCreated = (SubscriptionSet) -> Void
        private let callback: SubscriptionCreated

        init(_ callback: @escaping SubscriptionCreated) {
            self.callback = callback
        }

        func make(subscription: ManifestSubscription,
                  codecFactory: CodecFactory,
                  endpointId: String,
                  relayId: String) throws -> T {
            fatalError("Not implemented - make set")
        }

        func make(set: T,
                  profile: Profile,
                  codecFactory: CodecFactory,
                  endpointId: String,
                  relayId: String) throws -> K {
            fatalError("Not implemented - make subscription")
        }

        func create(subscription: ManifestSubscription,
                    codecFactory: CodecFactory,
                    endpointId: String,
                    relayId: String) throws -> SubscriptionSet {
            let set = try self.make(subscription: subscription,
                                    codecFactory: codecFactory,
                                    endpointId: endpointId,
                                    relayId: relayId)
            self.callback(set)
            return set
        }

        func create(set: any SubscriptionSet,
                    profile: Profile,
                    codecFactory: CodecFactory,
                    endpointId: String,
                    relayId: String,
                    publisherInitiated: Bool) throws -> Subscription {
            try self.make(set: set as! T, // swiftlint:disable:this force_cast
                          profile: profile,
                          codecFactory: codecFactory,
                          endpointId: endpointId,
                          relayId: relayId)
        }
    }

    class MockSubscription: Subscription, DisplayNotification {
        var mediaState = MediaState.subscribed

        init(profile: Profile) throws {
            try super.init(profile: profile,
                           endpointId: "1",
                           relayId: "2",
                           metricsSubmitter: nil,
                           priority: 0,
                           groupOrder: .originalPublisherOrder,
                           filterType: .none,
                           publisherInitiated: false,
                           statusCallback: nil)
        }

        // Pause/resume handling.
        private var internalPause = false
        override func pause() {
            super.pause()
            self.internalPause = true
        }
        override func resume() {
            super.resume()
            self.internalPause = false
        }
        override var isPaused: Bool {
            self.internalPause
        }

        // Display notification.
        private let callbacks = Mutex<DisplayCallbacks>(.init())
        func registerDisplayCallback(_ callback: @escaping DisplayCallback) -> Int {
            self.callbacks.store(callback)
        }
        func unregisterDisplayCallback(_ token: Int) {
            self.callbacks.remove(token)
        }
        func getMediaState() -> MediaState {
            self.mediaState
        }
        func fireDisplayCallbacks() {
            self.callbacks.fire()
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
                                                                      namespace: ["namespace"])]))

        var factoryCreated: Publication?
        let creationCallback: MockPublicationFactory.PublicationCreated = { factoryCreated = $0 }

        // Create controller.
        var published = false
        var unpublished = false
        let publish: MockClient.PublishTrackCallback = {
            published = $0 == factoryCreated
        }
        let unpublish: MockClient.PublishTrackCallback = {
            unpublished = $0 == factoryCreated
        }
        let subscribe: MockClient.SubscribeTrackCallback = { _ in }
        let unsubscribe: MockClient.SubscribeTrackCallback = { _ in }
        let fetch: MockClient.FetchTrackCallback = { _ in }
        let fetchCancel: MockClient.FetchTrackCallback = { _ in }
        let client = MockClient(publish: publish,
                                unpublish: unpublish,
                                subscribe: subscribe,
                                unsubscribe: unsubscribe,
                                fetch: fetch,
                                fetchCancel: fetchCancel)
        let controller = MoqCallController(endpointUri: "1", client: client, submitter: nil) { }
        try await controller.connect()

        // Calling publish should result in a matching publication being created from the factory, and a publish track being issued on it.
        try controller.publish(details: details, factory: MockPublicationFactory(creationCallback), codecFactory: MockCodecFactory())
        XCTAssert(published)

        // This publication should show as tracked.
        var publications = controller.getPublications()
        let namespace = details.profileSet.profiles.first!.namespace
        let ftn = try FullTrackName(namespace: namespace, name: "")
        XCTAssert(self.assertFtnEquality(publications.map { $0.getFullTrackName() }, rhs: [ftn]))

        // Removing should unpublish.
        try controller.unpublish(ftn)
        XCTAssert(unpublished)

        // No publications should be left.
        publications = controller.getPublications()
        XCTAssertEqual(publications, [])
    }

    func testSubscriptionSetAlter() async throws {
        let sourceID = "TESTING"
        let namespace = ["namespace"]
        let details = ManifestSubscription(mediaType: "video",
                                           sourceName: "test",
                                           sourceID: sourceID,
                                           label: "testLabel",
                                           participantId: .init(1),
                                           profileSet: .init(type: "video",
                                                             profiles: [
                                                                .init(qualityProfile: "h264",
                                                                      expiry: nil,
                                                                      priorities: nil,
                                                                      namespace: namespace)
                                                             ]))

        let expectedFtn: [QFullTrackName] = [try FullTrackName(namespace: namespace, name: "")]
        var factoryCreated: SubscriptionSet?
        let creationCallback: MockSubscriptionFactory.SubscriptionCreated = {
            factoryCreated = $0
        }
        let factory = MockSubscriptionFactory(creationCallback)

        // Create controller.
        let publish: MockClient.PublishTrackCallback = { _ in }
        let unpublish: MockClient.PublishTrackCallback = { _ in }
        var subscribed: [QFullTrackName] = []
        var unsubscribed: [QFullTrackName] = []
        let subscribe: MockClient.SubscribeTrackCallback = {
            subscribed.append($0.getFullTrackName())
        }
        let unsubscribe: MockClient.SubscribeTrackCallback = {
            unsubscribed.append($0.getFullTrackName())
        }
        let fetch: MockClient.FetchTrackCallback = { _ in }
        let client = MockClient(publish: publish,
                                unpublish: unpublish,
                                subscribe: subscribe,
                                unsubscribe: unsubscribe,
                                fetch: fetch,
                                fetchCancel: fetch)
        let controller = MoqCallController(endpointUri: "1", client: client, submitter: nil) { }
        try await controller.connect()

        // Subscribing to the set should cause a set to be created,
        // and subscribeTrack to be called on all contained subscriptions.
        let set = try controller.subscribeToSet(details: details,
                                                factory: factory,
                                                subscribeType: .subscribe)
        XCTAssertNotNil(factoryCreated)
        XCTAssert(self.assertFtnEquality(subscribed, rhs: expectedFtn))
        XCTAssertEqual(set.sourceId, sourceID)

        // Should show as tracked.
        var sets = controller.getSubscriptionSets()
        XCTAssertEqual([sourceID], sets.map { $0.sourceId })

        // Removing should unsubscribe.
        try controller.unsubscribeToSet(sourceID)
        XCTAssert(self.assertFtnEquality(unsubscribed, rhs: expectedFtn))

        // No sets should be left.
        sets = controller.getSubscriptionSets()
        XCTAssertEqual([], sets.map { $0.sourceId })
    }

    func testSubscriptionAlter() async throws {
        let sourceID = "TESTING"
        let namespace = ["namespace1"]
        let namespace2 = ["namespace2"]

        let profile1 = Profile(qualityProfile: "h264",
                               expiry: nil,
                               priorities: nil,
                               namespace: namespace)
        let profile2 = Profile(qualityProfile: "h264",
                               expiry: nil,
                               priorities: nil,
                               namespace: namespace2)

        let details = ManifestSubscription(mediaType: "video",
                                           sourceName: "test",
                                           sourceID: sourceID,
                                           label: "testLabel",
                                           participantId: .init(1),
                                           profileSet: .init(type: "video",
                                                             profiles: [
                                                                profile1,
                                                                profile2
                                                             ]))

        let ftn1 = try FullTrackName(namespace: namespace, name: "")
        let ftn2 = try FullTrackName(namespace: namespace2, name: "")

        XCTAssertEqual(ftn1, try .init(namespace: namespace, name: ""))
        XCTAssertEqual([ftn1], [try .init(namespace: namespace, name: "")])

        var factoryCreated: SubscriptionSet?
        let creationCallback: MockSubscriptionFactory.SubscriptionCreated = {
            factoryCreated = $0
        }
        let factory = MockSubscriptionFactory(creationCallback)

        // Create controller.
        let publish: MockClient.PublishTrackCallback = { _ in }
        let unpublish: MockClient.PublishTrackCallback = { _ in }
        var subscribed: [QFullTrackName] = []
        var unsubscribed: [QFullTrackName] = []
        let subscribe: MockClient.SubscribeTrackCallback = {
            subscribed.append($0.getFullTrackName())
        }
        let unsubscribe: MockClient.SubscribeTrackCallback = {
            unsubscribed.append($0.getFullTrackName())
        }
        let fetch: MockClient.FetchTrackCallback = { _ in }
        let client = MockClient(publish: publish,
                                unpublish: unpublish,
                                subscribe: subscribe,
                                unsubscribe: unsubscribe,
                                fetch: fetch,
                                fetchCancel: fetch)
        let controller = MoqCallController(endpointUri: "1",
                                           client: client,
                                           submitter: nil) { }
        try await controller.connect()

        // Subscribing to the set should cause a set to be created,
        // and subscribeTrack to be called on all contained subscriptions.
        let set = try controller.subscribeToSet(details: details, factory: factory, subscribeType: .subscribe)
        XCTAssertEqual(set.sourceId, sourceID)
        XCTAssertNotNil(factoryCreated)
        XCTAssert(self.assertFtnEquality(subscribed, rhs: [ftn1, ftn2]))
        subscribed = []

        // Handlers should show both.
        var handlers = factoryCreated!.getHandlers()
        XCTAssertEqual(handlers.count, 2)
        let ftns = handlers.map { $0.key }
        let compare: (FullTrackName, FullTrackName) -> Bool = {
            guard let left = String(data: Data($0.nameSpace.joined()), encoding: .utf8),
                  let right = String(data: Data($1.nameSpace.joined()), encoding: .utf8) else {
                return false
            }
            return left < right
        }
        XCTAssertEqual(ftns.sorted(by: compare), [ftn1, ftn2].sorted(by: compare))

        // Unsubscribe from one of the tracks.
        try controller.unsubscribe(factoryCreated!.sourceId, ftn: ftn1)
        // Unsubscribe track should have been called.
        XCTAssert(self.assertFtnEquality(unsubscribed, rhs: [ftn1]))

        // Handlers should show only one.
        handlers = factoryCreated!.getHandlers()
        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(handlers.keys.first, ftn2)

        // Resubscribe.
        try controller.subscribe(set: factoryCreated!, profile: profile1, factory: factory, publisherInitiated: nil)
        // Subscribe track should have been called.
        XCTAssert(self.assertFtnEquality(subscribed, rhs: [ftn1]))

        // Handlers should show both.
        handlers = factoryCreated!.getHandlers()
        XCTAssertEqual(handlers.count, 2)
        let ftns2 = handlers.map { $0.key }
        XCTAssert(self.assertFtnEquality(ftns2, rhs: [ftn1, ftn2]))
    }

    func testAssertFtnEquality() throws {
        let lhs: [QFullTrackName] = [try FullTrackName(namespace: ["a"], name: "a")]
        let rhs: [QFullTrackName] = [try FullTrackName(namespace: ["b"], name: "b")]
        XCTAssertTrue(self.assertFtnEquality(lhs, rhs: lhs))
        XCTAssertFalse(self.assertFtnEquality(lhs, rhs: rhs))
    }

    func assertFtnEquality(_ lhs: [QFullTrackName], rhs: [QFullTrackName]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var match = true
        for ftn in lhs {
            match = match && rhs.contains(where: { other in
                ftn.name == other.name && ftn.nameSpace == other.nameSpace
            })
        }
        return match
    }

    func testSubscriptionsByParticipantId() async throws {
        let mockClient = MockClient { _ in
        } unpublish: { _ in
        } subscribe: { _ in
        } unsubscribe: { _ in
        } fetch: { _ in
        } fetchCancel: { _ in
        }

        let callController = MoqCallController(endpointUri: "1", client: mockClient, submitter: nil) {}

        // Let matching.
        let matchingParticipantId: ParticipantId = .init(1)
        let matchingProfile = Profile(qualityProfile: "test", expiry: nil, priorities: nil, namespace: ["1"])
        let nonMatchingParticipantId: ParticipantId = .init(2)
        let nonMatchingProfile = Profile(qualityProfile: "test", expiry: nil, priorities: nil, namespace: ["2"])
        let matchingSubscription = ManifestSubscription(mediaType: "test",
                                                        sourceName: "test",
                                                        sourceID: "test",
                                                        label: "test",
                                                        participantId: matchingParticipantId,
                                                        profileSet: .init(type: "test",
                                                                          profiles: [ matchingProfile ]))
        let nonMatchingSubscription = ManifestSubscription(mediaType: "test",
                                                           sourceName: "test",
                                                           sourceID: "2",
                                                           label: "test",
                                                           participantId: nonMatchingParticipantId,
                                                           profileSet: .init(type: "test",
                                                                             profiles: [ nonMatchingProfile ]))

        try await callController.connect()
        let factory = MockSubscriptionFactory({ _ in })
        let matchingSet = try callController.subscribeToSet(details: matchingSubscription, factory: factory, subscribeType: .subscribe)
        let nonMatchingSet = try callController.subscribeToSet(details: nonMatchingSubscription, factory: factory, subscribeType: .subscribe)
        XCTAssertEqual(matchingSet.participantId, matchingParticipantId)
        XCTAssertEqual(nonMatchingSet.participantId, nonMatchingParticipantId)
        XCTAssertNotEqual(matchingSet.participantId, nonMatchingSet.participantId)
        let sets = try callController.getSubscriptionsByParticipant(matchingSet.participantId)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.getHandlers().count, 1)
        let retrievedFtn = FullTrackName(sets.first!.getHandlers().first!.value.getFullTrackName())
        XCTAssertEqual(retrievedFtn, try matchingProfile.getFullTrackName())
        XCTAssertNotEqual(retrievedFtn, try nonMatchingProfile.getFullTrackName())
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
