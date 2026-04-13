// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// A subscription that provides received objects via a callback.
class CallbackSubscription: Subscription {
    typealias SubscriptionCallback = (_ headers: QObjectHeaders,
                                      _ data: Data,
                                      _ extensions: HeaderExtensions?,
                                      _ immutableExtensions: HeaderExtensions?) -> Void
    private let callback: SubscriptionCallback

    init(fullTrackName: FullTrackName,
         endpointId: String,
         relayId: String,
         metricsSubmitter: MetricsSubmitter?,
         priority: UInt8,
         groupOrder: QGroupOrder,
         filterType: QFilterType,
         publisherInitiated: Bool,
         deliveryTimeout: UInt64?,
         callback: @escaping SubscriptionCallback,
         statusCallback: @escaping StatusCallback) throws {
        self.callback = callback
        try super.init(fullTrackName: fullTrackName,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: metricsSubmitter,
                       priority: priority,
                       groupOrder: groupOrder,
                       filterType: filterType,
                       publisherInitiated: publisherInitiated,
                       deliveryTimeout: deliveryTimeout,
                       statusCallback: statusCallback)
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders,
                                 data: Data,
                                 extensions: HeaderExtensions?,
                                 immutableExtensions: HeaderExtensions?,
                                 streamHeaderProperties: QStreamHeaderProperties?) {
        self.callback(objectHeaders, data, extensions, immutableExtensions)
    }
}
