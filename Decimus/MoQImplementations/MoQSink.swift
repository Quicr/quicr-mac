// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Protocol describing MoQ publish capability.
protocol MoQSink: AnyObject, Sendable {
    typealias OnStatus = @Sendable (QPublishTrackHandlerStatus) -> Void
    typealias OnMetrics = @Sendable (QPublishTrackMetrics) -> Void

    /// The full track name for this sink.
    var fullTrackName: FullTrackName { get }

    /// Current status of the publish track handler.
    var status: QPublishTrackHandlerStatus { get }

    /// Whether the sink is ready to publish objects.
    var canPublish: Bool { get }

    /// Install the status and metrics callbacks and begin delivering them.
    /// Callbacks fire on the underlying transport thread.
    /// - Parameter onStatus: Status callback.
    /// - Parameter onMetrics: Metrics callback.
    func setCallbacks(onStatus: @escaping OnStatus, onMetrics: @escaping OnMetrics)

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
                       immutableExtensions: HeaderExtensions?,
                       streamHeaderProperties: QStreamHeaderProperties?) -> QPublishObjectStatus

    /// End the given subgroup.
    func endSubgroup(groupId: UInt64, subgroupId: UInt64, completed: Bool)
}
