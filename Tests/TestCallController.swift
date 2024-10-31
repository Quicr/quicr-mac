// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import XCTest
@testable import QuicR

final class TestCallController: XCTestCase {

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

    func testPublicationAdd() {
        let publish: MockClient.PublishTrackCallback = { _ in }
        let unpublished: MockClient.UnpublishTrackCallback = { _ in }
        let subscribe: MockClient.SubscribeTrackCallback = { _ in }
        let unsubscribe: MockClient.UnsubscribeTrackCallback = { _ in }
        let client = MockClient(publish: publish, unpublish: unpublished, subscribe: subscribe, unsubscribe: unsubscribe)
        let controller = MoqCallController(endpointUri: <#T##String#>,
                                           client: <#T##any MoqClient#>,
                                           captureManager: <#T##CaptureManager#>,
                                           subscriptionConfig: <#T##SubscriptionConfig#>,
                                           engine: <#T##DecimusAudioEngine#>,
                                           videoParticipants: <#T##VideoParticipants#>,
                                           submitter: <#T##(any MetricsSubmitter)?#>,
                                           granularMetrics: <#T##Bool#>,
                                           callEnded: <#T##() -> Void#>)
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
