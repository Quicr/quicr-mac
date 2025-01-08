// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Base implementation for a track handler, handling generic metrics and callbacks.
class Subscription: QSubscribeTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
    private let quicrMeasurement: MeasurementRegistration<TrackMeasurement>?
    private let logger = DecimusLogger(Subscription.self)

    /// Create a new subscription for the given profile.
    /// - Parameters:
    ///   - profile: Details of the track to subscribe to.
    ///   - endpointId: Metrics identifier.
    ///   - relayId: Metrics identifier.
    ///   - metricsSubmitter: Optionally, submitter for metrics.
    ///   - priority: Priority for the subscription.
    ///   - groupOrder: Subscription for group order.
    ///   - filterType: Filter type.
    init(profile: Profile,
         endpointId: String,
         relayId: String,
         metricsSubmitter: MetricsSubmitter?,
         priority: UInt8,
         groupOrder: QGroupOrder,
         filterType: QFilterType) throws {
        if let submitter = metricsSubmitter {
            self.quicrMeasurement = .init(measurement: .init(type: .subscribe,
                                                             endpointId: endpointId,
                                                             relayId: relayId,
                                                             namespace: profile.namespace.joined()),
                                          submitter: submitter)
        } else {
            self.quicrMeasurement = nil
        }
        super.init(fullTrackName: try profile.getFullTrackName(),
                   priority: priority,
                   groupOrder: groupOrder,
                   filterType: filterType)
        super.setCallbacks(self)
    }

    /// Fires when the underlying subscription handler's status changes.
    /// - Parameter status: The updated status.
    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.debug("Status changed: \(status)")
    }

    /// Fires when a full object has been received.
    /// - Parameters:
    ///   - objectHeaders: The headers for this object.
    ///   - data: Object payload bytes.
    ///   - extensions: Header extensions, if any.
    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {}

    /// Fires when a partial object has been received.
    /// - Parameters:
    ///   - objectHeaders: The headers for this object.
    ///   - data: Object payload bytes.
    ///   - extensions: Header extensions, if any.
    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {}

    /// Fires when the underlying handler produces metrics.
    /// The default implementation submits these metrics through the provided submitter, if any.
    /// - Parameter metrics: The produced track metrics.
    func metricsSampled(_ metrics: QSubscribeTrackMetrics) {
        if let quicrMeasurement = self.quicrMeasurement {
            Task(priority: .utility) {
                await quicrMeasurement.measurement.record(metrics)
            }
        }
    }
}
