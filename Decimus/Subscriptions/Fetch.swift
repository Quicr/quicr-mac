// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

/// Represents a MoQ Fetch operation.
class Fetch: QFetchTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
    private let logger = DecimusLogger(Fetch.self)
    private let verbose: Bool
    private let quicrMeasurement: MeasurementRegistration<TrackMeasurement>?
    private let isCompleteInternal: Atomic<Bool> = .init(false)

    /// Create a new fetch handler.
    /// - Parameters:
    ///     - ftn: Full track name of the track to fetch.
    ///     - priority: The priority of the fetch operation.
    ///     - groupOrder: Requested delivery order of the fetched groups.
    ///     - startLocation: The starting location of the fetch (group and object IDs).
    ///     - endLocation: The ending location of the fetch (group ID, and optionally object ID for partial group).
    ///     - verbose: Verbose logging.
    ///     - metricsSubmitter: Optionally, submitter for metrics.
    ///     - endpointId: Endpoint ID for metrics.
    ///     - relayId: Connected relayId for metrics.
    init(_ ftn: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         startLocation: QLocation,
         endLocation: QFetchEndLocation,
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
                   start: startLocation,
                   endLocation: endLocation)
        super.setCallbacks(self)
    }

    func isComplete() -> Bool {
        self.isCompleteInternal.load(ordering: .acquiring)
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.debug("Status changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders,
                        data: Data,
                        extensions: HeaderExtensions?,
                        immutableExtensions: HeaderExtensions?) {
        let endLocation = self.getEndLocation()
        // TODO: Non absolute ranged groups won't complete like this.
        if objectHeaders.groupId == endLocation.group,
           let endObject = endLocation.object?.uint64Value,
           objectHeaders.objectId == endObject {
            self.isCompleteInternal.store(true, ordering: .releasing)
        }
        guard self.verbose else { return }
        self.logger.debug("Object fetched: \(objectHeaders.groupId):\(objectHeaders.objectId)")
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders,
                               data: Data,
                               extensions: HeaderExtensions?,
                               immutableExtensions: HeaderExtensions?) {
        guard self.verbose else { return }
        self.logger.debug("Partial object fetched: \(objectHeaders.groupId):\(objectHeaders.objectId)")
    }

    func metricsSampled(_ metrics: QSubscribeTrackMetrics) {
        if let measurement = self.quicrMeasurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }
}
