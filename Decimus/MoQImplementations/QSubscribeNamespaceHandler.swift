// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Protocol describing MoQ subscribe-namespace capability.
protocol MoQSubscribeNamespaceHandler: AnyObject {
    typealias StatusCallback = (_ status: QSubscribeNamespaceHandlerStatus,
                                _ errorCode: QSubscribeNamespaceErrorCode,
                                _ namespacePrefix: NamespacePrefix) -> Void
    typealias TrackReceivedCallback = (_ fullTrackName: FullTrackName,
                                       _ attributes: QPublishAttributes) -> Subscription?

    /// Callback invoked when the subscribe-namespace status changes.
    var statusChangedCallback: StatusCallback { get }

    /// Callback invoked when a track becomes available in the subscribed namespace.
    /// Return `true` to accept and subscribe the track, `false` to decline.
    var trackReceivedCallback: TrackReceivedCallback { get }

    /// The namespace prefix this handler subscribes to.
    var namespacePrefix: NamespacePrefix { get }

    /// Current status of the namespace subscription.
    var status: QSubscribeNamespaceHandlerStatus { get }
}

/// MoQ subscribe-namespace handler using libquicr.
final class QSubscribeNamespaceHandler: NSObject, MoQSubscribeNamespaceHandler, QSubscribeNamespaceHandlerCallbacks {
    let statusChangedCallback: StatusCallback
    let trackReceivedCallback: TrackReceivedCallback

    /// The underlying libquicr handler.
    let handler: QSubscribeNamespaceHandlerObjC

    var namespacePrefix: NamespacePrefix {
        .init(self.handler.getNamespacePrefix())
    }

    var status: QSubscribeNamespaceHandlerStatus {
        self.handler.getStatus()
    }

    /// Creates a new libquicr subscribe-namespace handler.
    /// - Parameter namespacePrefix: Namespace prefix to subscribe to.
    init(namespacePrefix: NamespacePrefix,
         trackFilter: QTrackFilterObjC? = nil,
         statusChangedCallback: @escaping StatusCallback,
         trackReceivedCallback: @escaping TrackReceivedCallback) {
        self.handler = .init(namespacePrefix: namespacePrefix.elements, trackFilter: trackFilter)
        self.statusChangedCallback = statusChangedCallback
        self.trackReceivedCallback = trackReceivedCallback
        super.init()
        self.handler.setCallbacks(self)
    }

    func statusChanged(_ status: QSubscribeNamespaceHandlerStatus, errorCode: QSubscribeNamespaceErrorCode) {
        self.statusChangedCallback(status, errorCode, self.namespacePrefix)
    }

    func newTrackReceived(_ tfn: QFullTrackName, attributes: QPublishAttributes) -> QSubscribeTrackHandlerObjC? {
        self.trackReceivedCallback(.init(tfn), attributes)
    }
}
