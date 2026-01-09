// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// MoQSink using libquicr.
final class QPublishTrackHandlerSink: NSObject, MoQSink, QPublishTrackHandlerCallbacks {
    weak var delegate: MoQSinkDelegate?

    /// The underlying libquicr handler.
    let handler: QPublishTrackHandlerObjC

    var fullTrackName: QFullTrackName {
        self.handler.getFullTrackName()
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
    ///   - useAnnounce: Whether to use announce.
    init(fullTrackName: QFullTrackName,
         trackMode: QTrackMode,
         defaultPriority: UInt8,
         defaultTTL: UInt32,
         useAnnounce: Bool) {
        self.handler = .init(fullTrackName: fullTrackName,
                             trackMode: trackMode,
                             defaultPriority: defaultPriority,
                             defaultTTL: defaultTTL)
        super.init()
        self.handler.setCallbacks(self)
        self.handler.setUseAnnounce(useAnnounce)
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

    // MARK: - QPublishTrackHandlerCallbacks

    func statusChanged(_ status: QPublishTrackHandlerStatus) {
        self.delegate?.sinkStatusChanged(status)
    }

    func metricsSampled(_ metrics: QPublishTrackMetrics) {
        self.delegate?.sinkMetricsSampled(metrics)
    }
}
