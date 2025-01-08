// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// A subscription that provides received objects via a callback.
class CallbackSubscription: Subscription {
    typealias SubscriptionCallback = (QObjectHeaders, Data, [NSNumber: Data]?) -> Void
    private let callback: SubscriptionCallback

    init(profile: Profile,
         endpointId: String,
         relayId: String,
         metricsSubmitter: MetricsSubmitter?,
         priority: UInt8,
         groupOrder: QGroupOrder,
         filterType: QFilterType,
         callback: @escaping SubscriptionCallback) throws {
        self.callback = callback
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: metricsSubmitter,
                       priority: priority,
                       groupOrder: groupOrder,
                       filterType: filterType)
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.callback(objectHeaders, data, extensions)
    }
}
