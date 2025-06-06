// SPDX-FileCopyrightText: Copyright (c) 2025 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Synchronization

/// A subscription that provides received objects via a callback.
class MultipleCallbackSubscription: Subscription {
    struct Callbacks: ~Copyable {
        var callbacks: [Int: CallbackSubscription.SubscriptionCallback] = [:]
        var latestToken = 0
    }
    private let callbacks: Mutex<Callbacks> = .init(.init())

    init(profile: Profile,
         endpointId: String,
         relayId: String,
         metricsSubmitter: MetricsSubmitter?,
         priority: UInt8,
         groupOrder: QGroupOrder,
         filterType: QFilterType,
         statusCallback: @escaping StatusCallback) throws {
        try super.init(profile: profile,
                       endpointId: endpointId,
                       relayId: relayId,
                       metricsSubmitter: metricsSubmitter,
                       priority: priority,
                       groupOrder: groupOrder,
                       filterType: filterType,
                       statusCallback: statusCallback)
    }

    func addCallback(_ callback: @escaping CallbackSubscription.SubscriptionCallback) -> Int {
        self.callbacks.withLock { locked in
            let token = locked.latestToken
            locked.callbacks[token] = callback
            locked.latestToken += 1
            return token
        }
    }

    func removeCallback(_ token: Int) {
        self.callbacks.withLock { locked in
            _ = locked.callbacks.removeValue(forKey: token)
        }
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.callbacks.withLock { locked in
            for callback in locked.callbacks.values {
                callback(objectHeaders, data, extensions)
            }
        }
    }
}
