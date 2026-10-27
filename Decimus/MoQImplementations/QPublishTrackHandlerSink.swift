// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import Synchronization

/// Transport side callbacks.
private final class PublishCallbackBox: QPublishTrackHandlerCallbacks, Sendable {
    struct Installed {
        let onStatus: MoQSink.OnStatus
        let onMetrics: MoQSink.OnMetrics
    }
    private let installed = Mutex<Installed?>(nil)
    private let logger: DecimusLogger

    init(logger: DecimusLogger) {
        self.logger = logger
    }

    func install(onStatus: @escaping MoQSink.OnStatus, onMetrics: @escaping MoQSink.OnMetrics) {
        self.installed.withLock { $0 = .init(onStatus: onStatus, onMetrics: onMetrics) }
    }

    func statusChanged(_ status: QPublishTrackHandlerStatus) {
        guard let callbacks = self.installed.get() else {
            self.logger.warning("Callbacks not installed")
            return
        }
        callbacks.onStatus(status)
    }

    func metricsSampled(_ metrics: QPublishTrackMetrics) {
        guard let callbacks = self.installed.get() else {
            self.logger.warning("Callbacks not installed")
            return
        }
        callbacks.onMetrics(metrics)
    }
}

/// MoQSink using libquicr.
final class QPublishTrackHandlerSink: MoQSink {
    /// The underlying libquicr handler.
    let handler: QPublishTrackHandlerObjC

    private let callbacks: PublishCallbackBox
    private let publisherPriority: UInt8
    private let publishObjectPriority: UInt8

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
    ///   - publisherPriority: Default priority for published objects.
    ///   - publishObjectPriority: Local transport scheduling priority; defaults to the publisher priority.
    ///   - defaultTTL: Default TTL for published objects.
    init(fullTrackName: QFullTrackName,
         trackMode: QTrackMode,
         publisherPriority: UInt8,
         publishObjectPriority: UInt8? = nil,
         defaultTTL: UInt32) {
        let callbacks = PublishCallbackBox(logger: .init(QPublishTrackHandlerSink.self,
                                                         prefix: "\(fullTrackName)"))
        self.callbacks = callbacks
        self.publisherPriority = publisherPriority
        self.publishObjectPriority = publishObjectPriority ?? publisherPriority
        self.handler = .init(fullTrackName: fullTrackName,
                             trackMode: trackMode,
                             publisherPriority: publisherPriority,
                             publishObjectPriority: publishObjectPriority ?? publisherPriority,
                             defaultTTL: defaultTTL,
                             callbacks: callbacks)
    }

    func setCallbacks(onStatus: @escaping OnStatus, onMetrics: @escaping OnMetrics) {
        self.callbacks.install(onStatus: onStatus, onMetrics: onMetrics)
    }

    func publishObject(_ headers: QObjectHeaders,
                       data: Data,
                       extensions: HeaderExtensions?,
                       immutableExtensions: HeaderExtensions?,
                       streamHeaderProperties: QStreamHeaderProperties?) -> QPublishObjectStatus {
        // Apply per-object priorities explicitly; libquicr publishes using handler priorities.
        if let priority = headers.priority?.pointee {
            self.handler.setPublisherPriority(priority)
            self.handler.setPublishObjectPriority(priority)
        }
        defer {
            self.handler.setPublisherPriority(self.publisherPriority)
            self.handler.setPublishObjectPriority(self.publishObjectPriority)
        }
        return self.handler.publishObject(headers,
                                          data: data,
                                          extensions: extensions,
                                          immutableExtensions: immutableExtensions,
                                          streamHeaderProperties: streamHeaderProperties)
    }

    func endSubgroup(groupId: UInt64, subgroupId: UInt64, completed: Bool) {
        self.handler.endSubgroup(groupId, subgroupId: subgroupId, completed: completed)
    }
}
