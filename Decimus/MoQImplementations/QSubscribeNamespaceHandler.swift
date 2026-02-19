// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Protocol describing MoQ subscribe-namespace capability.
protocol MoQSubscribeNamespaceHandler: AnyObject {
    typealias StatusCallback = (_ status: QSubscribeNamespaceHandlerStatus,
                                _ errorCode: QSubscribeNamespaceErrorCode,
                                _ namespacePrefix: [Data]) -> Void
    typealias TrackAcceptableCallback = (_ fullTrackName: FullTrackName) -> Bool

    /// Callback invoked when the subscribe-namespace status changes.
    var statusChangedCallback: StatusCallback { get }

    /// Callback invoked when a track becomes available in the subscribed namespace.
    /// Return `true` to accept and subscribe the track, `false` to decline.
    var trackAcceptableCallback: TrackAcceptableCallback { get }

    /// The namespace prefix this handler subscribes to.
    var namespacePrefix: [Data] { get }

    /// Current status of the namespace subscription.
    var status: QSubscribeNamespaceHandlerStatus { get }
}

/// MoQ subscribe-namespace handler using libquicr.
final class QSubscribeNamespaceHandler: NSObject, MoQSubscribeNamespaceHandler, QSubscribeNamespaceHandlerCallbacks {
    let statusChangedCallback: StatusCallback
    let trackAcceptableCallback: TrackAcceptableCallback

    /// The underlying libquicr handler.
    let handler: QSubscribeNamespaceHandlerObjC

    var namespacePrefix: [Data] {
        self.handler.getNamespacePrefix()
    }

    var status: QSubscribeNamespaceHandlerStatus {
        self.handler.getStatus()
    }

    /// Creates a new libquicr subscribe-namespace handler.
    /// - Parameter namespacePrefix: Namespace prefix to subscribe to.
    init(namespacePrefix: [Data],
         statusChangedCallback: @escaping StatusCallback,
         trackAcceptableCallback: @escaping TrackAcceptableCallback) {
        self.handler = .init(namespacePrefix: namespacePrefix)
        self.statusChangedCallback = statusChangedCallback
        self.trackAcceptableCallback = trackAcceptableCallback
        super.init()
        self.handler.setCallbacks(self)
    }

    func statusChanged(_ status: QSubscribeNamespaceHandlerStatus, errorCode: QSubscribeNamespaceErrorCode) {
        self.statusChangedCallback(status, errorCode, self.namespacePrefix)
    }

    /// Callback for when notification of a matched track arrives.
    /// - Returns True to accept this track and subscribe, false to ignore.
    func isTrackAcceptable(_ fullTrackName: any QFullTrackName) -> Bool {
        return self.trackAcceptableCallback(.init(fullTrackName))
    }
}
