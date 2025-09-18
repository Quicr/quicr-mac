// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// A ``Fetch`` operation that calls back received objects and statuses.
class CallbackFetch: Fetch {
    private let statusChanged: Subscription.StatusCallback?
    private let objectReceived: CallbackSubscription.SubscriptionCallback?

    /// Create a new fetch handler for callbacks.
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
    ///     - statusChanged: A callback to be called when the fetch handler's status changes.
    ///     - objectReceived: A callback to be called when a fetched object arrives.
    init(ftn: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         startGroup: UInt64,
         endGroup: UInt64,
         startObject: UInt64,
         endObject: UInt64,
         verbose: Bool,
         metricsSubmitter: MetricsSubmitter?,
         endpointId: String,
         relayId: String,
         statusChanged: Subscription.StatusCallback?,
         objectReceived: CallbackSubscription.SubscriptionCallback?) {
        self.statusChanged = statusChanged
        self.objectReceived = objectReceived
        super.init(ftn,
                   priority: priority,
                   groupOrder: groupOrder,
                   startGroup: startGroup,
                   endGroup: endGroup,
                   startObject: startObject,
                   endObject: endObject,
                   verbose: verbose,
                   metricsSubmitter: metricsSubmitter,
                   endpointId: endpointId,
                   relayId: relayId)
    }

    override func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        super.statusChanged(status)
        self.statusChanged?(status)
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders,
                                 data: Data,
                                 extensions: HeaderExtensions?,
                                 immutableExtensions: HeaderExtensions?) {
        super.objectReceived(objectHeaders,
                             data: data,
                             extensions: extensions,
                             immutableExtensions: immutableExtensions)
        self.objectReceived?(objectHeaders, data, extensions, immutableExtensions)
    }
}
