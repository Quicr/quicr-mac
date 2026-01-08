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
