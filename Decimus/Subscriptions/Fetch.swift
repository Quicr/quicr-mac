// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Represents a MoQ Fetch operation.
class Fetch: QFetchTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
    private let logger = DecimusLogger(Fetch.self)
    private let verbose: Bool
    private let quicrMeasurement: MeasurementRegistration<TrackMeasurement>?

    /// Create a new fetch handler.
    /// - Parameters:
    ///     - ftn: Full track name of the track to fetch.
    ///     - priority: The priority of the fetch operation.
    ///     - groupOrder: Requested delivery order of the fetched groups.
    ///     - startGroup: The group ID to fetch from.
    ///     - endGroup: The group ID to fetch up to and including.
    ///     - startObject: The object ID in ``startGroup`` to fetch from.
    ///     - endObject: The object ID in ``endGroup`` to fetch from, plus 1.
    ///     - verbose: Verbose logging.
    ///     - metricsSubmitter: Optionally, submitter for metrics.
    ///     - endpointId: Endpoint ID for metrics.
    ///     - relayId: Connected relayId for metrics.
    init(_ ftn: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         startGroup: UInt64,
         endGroup: UInt64,
         startObject: UInt64,
         endObject: UInt64,
         verbose: Bool,
         metricsSubmitter: MetricsSubmitter?,
         endpointId: String,
         relayId: String) {
        self.verbose = verbose
        if let submitter = metricsSubmitter {
            let namespace = ftn.nameSpace.reduce(into: "") { partialResult, element in
                if let string = String(data: element, encoding: .utf8) {
                    partialResult.append(string)
                }
            }
            self.quicrMeasurement = .init(measurement: .init(type: .fetch,
                                                             endpointId: endpointId,
                                                             relayId: relayId,
                                                             namespace: namespace),
                                          submitter: submitter)
        } else {
            self.quicrMeasurement = nil
        }
        super.init(fullTrackName: ftn,
                   priority: priority,
                   groupOrder: groupOrder,
                   startGroup: startGroup,
                   endGroup: endGroup,
                   startObject: startObject,
                   endObject: endObject)
        super.setCallbacks(self)
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.debug("Status changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        guard self.verbose else { return }
        self.logger.debug("Object received: \(objectHeaders.groupId):\(objectHeaders.objectId)")
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        guard self.verbose else { return }
        self.logger.debug("Partial object received: \(objectHeaders.groupId):\(objectHeaders.objectId)")
    }

    func metricsSampled(_ metrics: QSubscribeTrackMetrics) {
        if let measurement = self.quicrMeasurement?.measurement {
            measurement.record(metrics)
        }
    }
}
