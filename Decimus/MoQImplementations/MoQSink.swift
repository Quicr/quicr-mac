// SPDX-FileCopyrightText: Copyright (c) 2026 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Delegate protocol for receiving status and metrics callbacks from a MoQSink.
/// Publications conform to this protocol to receive notifications from the underlying MoQ stack.
protocol MoQSinkDelegate: AnyObject {
    /// Called when the publish track handler status changes.
    /// - Parameter status: The new status.
    func sinkStatusChanged(_ status: QPublishTrackHandlerStatus)

    /// Called when metrics are sampled from the underlying transport.
    /// - Parameter metrics: The sampled metrics.
    func sinkMetricsSampled(_ metrics: QPublishTrackMetrics)
}

/// Protocol describing MoQ publish capability.
protocol MoQSink: AnyObject {
    /// The delegate to receive status and metrics callbacks.
    var delegate: MoQSinkDelegate? { get set }

    /// The full track name for this sink.
    var fullTrackName: FullTrackName { get }

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

    /// End the given subgroup.
    func endSubgroup(groupId: UInt64, subgroupId: UInt64, completed: Bool)
}

typealias MoQSubscribeNamespaceStatusCallback = (_ status: QSubscribeNamespaceHandlerStatus,
                                                 _ errorCode: QSubscribeNamespaceErrorCode,
                                                 _ namespacePrefix: [Data]) -> Void

/// Protocol describing MoQ subscribe-namespace capability.
protocol MoQSubscribeNamespaceHandler: AnyObject {
    /// Callback invoked when the subscribe-namespace status changes.
    var statusChangedCallback: MoQSubscribeNamespaceStatusCallback? { get set }

    /// The namespace prefix this handler subscribes to.
    var namespacePrefix: [Data] { get }

    /// Current status of the namespace subscription.
    var status: QSubscribeNamespaceHandlerStatus { get }
}
