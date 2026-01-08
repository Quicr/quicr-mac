// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Protocol describing MoQ publish capability.
protocol MoQSink: AnyObject {
    /// The delegate to receive status and metrics callbacks.
    var delegate: MoQSinkDelegate? { get set }

    /// The full track name for this sink.
    var fullTrackName: QFullTrackName { get }

    /// Current status of the publish track handler.
    var status: QPublishTrackHandlerStatus { get }

    /// Whether the sink is ready to publish objects.
    var canPublish: Bool { get }

    /// Publish a complete object.
    /// - Parameters:
    ///   - headers: Object headers including group/object IDs, payload length, priority, TTL.
    ///   - data: The payload data.
    ///   - extensions: Optional mutable header extensions.
    ///   - immutableExtensions: Optional immutable header extensions.
    /// - Returns: Status indicating success or failure reason.
    func publishObject(_ headers: QObjectHeaders,
                       data: Data,
                       extensions: HeaderExtensions?,
                       immutableExtensions: HeaderExtensions?) -> QPublishObjectStatus
}
