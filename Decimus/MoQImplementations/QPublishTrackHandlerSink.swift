// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// MoQSink using libquicr.
final class QPublishTrackHandlerSink: NSObject, MoQSink, QPublishTrackHandlerCallbacks {
    weak var delegate: MoQSinkDelegate?

    /// The underlying libquicr handler.
    let handler: QPublishTrackHandlerObjC

    var fullTrackName: FullTrackName {
        .init(self.handler.getFullTrackName())
    }

    var status: QPublishTrackHandlerStatus {
        self.handler.getStatus()
    }

    var canPublish: Bool {
        self.handler.canPublish()
    }

    /// Creates a new libquicr sink.
    /// - Parameters:
    ///   - fullTrackName: The full track name for this publication.
    ///   - trackMode: The track mode (datagram or stream).
    ///   - defaultPriority: Default priority for published objects.
    ///   - defaultTTL: Default TTL for published objects.
    init(fullTrackName: QFullTrackName,
         trackMode: QTrackMode,
         defaultPriority: UInt8,
         defaultTTL: UInt32) {
        self.handler = .init(fullTrackName: fullTrackName,
                             trackMode: trackMode,
                             defaultPriority: defaultPriority,
                             defaultTTL: defaultTTL)
        super.init()
        self.handler.setCallbacks(self)
    }

    func publishObject(_ headers: QObjectHeaders,
                       data: Data,
                       extensions: HeaderExtensions?,
                       immutableExtensions: HeaderExtensions?) -> QPublishObjectStatus {
        self.handler.publishObject(headers,
                                   data: data,
                                   extensions: extensions,
                                   immutableExtensions: immutableExtensions)
    }

    func endSubgroup(groupId: UInt64, subgroupId: UInt64, completed: Bool) {
        self.handler.endSubgroup(groupId, subgroupId: subgroupId, completed: completed)
    }

    func statusChanged(_ status: QPublishTrackHandlerStatus) {
        self.delegate?.sinkStatusChanged(status)
    }

    func metricsSampled(_ metrics: QPublishTrackMetrics) {
        self.delegate?.sinkMetricsSampled(metrics)
    }
}

/// MoQ subscribe-namespace handler using libquicr.
final class QSubscribeNamespaceHandler: NSObject, MoQSubscribeNamespaceHandler, QSubscribeNamespaceHandlerCallbacks {
    weak var delegate: MoQSubscribeNamespaceHandlerDelegate?

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
    init(namespacePrefix: [Data]) {
        self.handler = .init(namespacePrefix: namespacePrefix)
        super.init()
        self.handler.setCallbacks(self)
    }

    func statusChanged(_ status: QSubscribeNamespaceHandlerStatus, errorCode: QSubscribeNamespaceErrorCode) {
        self.delegate?.statusChanged(status,
                                                     errorCode: errorCode,
                                                     namespacePrefix: self.namespacePrefix)
    }
}
