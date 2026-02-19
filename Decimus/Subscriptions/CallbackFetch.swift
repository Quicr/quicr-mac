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
    ///     - startLocation: The starting location of the fetch (group and object IDs).
    ///     - endLocation: The ending location of the fetch (group ID, and optionally object ID for partial group).
    ///     - verbose: Verbose logging.
    ///     - metricsSubmitter: Optionally, submitter for metrics.
    ///     - endpointId: Endpoint ID for metrics.
    ///     - relayId: Connected relayId for metrics.
    ///     - statusChanged: A callback to be called when the fetch handler's status changes.
    ///     - objectReceived: A callback to be called when a fetched object arrives.
    init(ftn: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         startLocation: QLocation,
         endLocation: QFetchEndLocation,
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
                   startLocation: startLocation,
                   endLocation: endLocation,
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
