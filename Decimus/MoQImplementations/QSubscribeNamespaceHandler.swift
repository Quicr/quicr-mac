// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Protocol describing MoQ subscribe-namespace capability.
protocol MoQSubscribeNamespaceHandler: AnyObject {
    typealias StatusCallback = (_ status: QSubscribeNamespaceHandlerStatus,
                                _ errorCode: QSubscribeNamespaceErrorCode,
                                _ namespacePrefix: [Data]) -> Void
    typealias TrackAcceptableCallback = (_ fullTrackName: FullTrackName) -> Bool
    typealias CreateHandlerCallback = (_ fullTrackName: FullTrackName,
                                       _ trackAlias: UInt64,
                                       _ priority: UInt8,
                                       _ groupOrder: QGroupOrder,
                                       _ filterType: QFilterType) -> QSubscribeTrackHandlerObjC?

    /// Callback invoked when the subscribe-namespace status changes.
    var statusChangedCallback: StatusCallback { get }

    /// Callback invoked when a track becomes available in the subscribed namespace.
    /// Return `true` to accept and subscribe the track, `false` to decline.
    var trackAcceptableCallback: TrackAcceptableCallback { get }

    /// Callback invoked to create a subscription handler for an accepted track.
    /// Return nil to use the default handler.
    var createHandlerCallback: CreateHandlerCallback? { get }

    /// The namespace prefix this handler subscribes to.
    var namespacePrefix: [Data] { get }

    /// Current status of the namespace subscription.
    var status: QSubscribeNamespaceHandlerStatus { get }
}

/// MoQ subscribe-namespace handler using libquicr.
final class QSubscribeNamespaceHandler: NSObject, MoQSubscribeNamespaceHandler, QSubscribeNamespaceHandlerCallbacks {
    let statusChangedCallback: StatusCallback
    let trackAcceptableCallback: TrackAcceptableCallback
    let createHandlerCallback: CreateHandlerCallback?

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
         trackAcceptableCallback: @escaping TrackAcceptableCallback,
         createHandlerCallback: CreateHandlerCallback? = nil) {
        self.handler = .init(namespacePrefix: namespacePrefix)
        self.statusChangedCallback = statusChangedCallback
        self.trackAcceptableCallback = trackAcceptableCallback
        self.createHandlerCallback = createHandlerCallback
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

    /// Callback to create a subscription handler for an accepted track.
    func createHandler(_ fullTrackName: any QFullTrackName,
                       trackAlias: UInt64,
                       priority: UInt8,
                       groupOrder: QGroupOrder,
                       filterType: QFilterType) -> QSubscribeTrackHandlerObjC? {
        return self.createHandlerCallback?(.init(fullTrackName), trackAlias, priority, groupOrder, filterType)
    }
}
