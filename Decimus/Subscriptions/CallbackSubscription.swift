// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// A subscription that provides received objects via a callback.
class CallbackSubscription: QSubscribeTrackHandlerObjC, QSubscribeTrackHandlerCallbacks {
    typealias SubscriptionCallback = (QObjectHeaders, Data, [NSNumber: Data]?) -> Void
    private let logger = DecimusLogger(CallbackSubscription.self)
    private let callback: SubscriptionCallback

    init(fullTrackName: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         callback: @escaping SubscriptionCallback) {
        self.callback = callback
        super.init(fullTrackName: fullTrackName,
                   priority: priority,
                   groupOrder: groupOrder)
    }

    func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        self.logger.info("Status changed: \(status)")
    }

    func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.callback(objectHeaders, data, extensions)
    }

    func partialObjectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        self.logger.warning("Unexpected partial object received")
    }

    func metricsSampled(_ metrics: QSubscribeTrackMetrics) {
        // TODO: Record metrics.
    }
}
