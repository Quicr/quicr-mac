// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

@testable import QuicR

// swiftlint:disable force_cast
class MockClient: MoqClient {
    typealias PublishTrackCallback = (Publication) -> Void
    typealias SubscribeTrackCallback = (Subscription) -> Void
    typealias FetchTrackCallback = (Fetch) -> Void
    private let publish: PublishTrackCallback
    private let unpublish: PublishTrackCallback
    private let subscribe: SubscribeTrackCallback
    private let unsubscribe: SubscribeTrackCallback
    private let fetch: FetchTrackCallback
    private let fetchCancel: FetchTrackCallback
    private var callbacks: QClientCallbacks?

    init(publish: @escaping PublishTrackCallback,
         unpublish: @escaping PublishTrackCallback,
         subscribe: @escaping SubscribeTrackCallback,
         unsubscribe: @escaping SubscribeTrackCallback,
         fetch: @escaping FetchTrackCallback,
         fetchCancel: @escaping FetchTrackCallback) {
        self.publish = publish
        self.unpublish = unpublish
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
        self.fetch = fetch
        self.fetchCancel = fetchCancel
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
        self.publish(handler as! Publication)
    }

    func unpublishTrack(withHandler handler: QPublishTrackHandlerObjC) {
        self.unpublish(handler as! Publication)
    }

    func publishAnnounce(_ trackNamespace: Data) { }
    func publishUnannounce(_ trackNamespace: Data) {}

    func setCallbacks(_ callbacks: any QClientCallbacks) {
        self.callbacks = callbacks
    }

    func subscribeTrack(withHandler handler: QSubscribeTrackHandlerObjC) {
        self.subscribe(handler as! Subscription)
    }

    func unsubscribeTrack(withHandler handler: QSubscribeTrackHandlerObjC) {
        self.unsubscribe(handler as! Subscription)
    }

    func fetchTrack(withHandler handler: QFetchTrackHandlerObjC) {
        self.fetch(handler as! Fetch)
    }

    func cancelFetchTrack(withHandler handler: QFetchTrackHandlerObjC) {
        self.fetchCancel(handler as! Fetch)
    }

    func getAnnounceStatus(_ trackNamespace: Data) -> QPublishAnnounceStatus {
        .OK
    }
}
// swiftlint:enable force_cast
