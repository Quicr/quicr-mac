// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

class CallbackFetch: Fetch {
    private let statusChanged: Subscription.StatusCallback?
    private let objectReceived: CallbackSubscription.SubscriptionCallback?

    init(ftn: FullTrackName,
         priority: UInt8,
         groupOrder: QGroupOrder,
         startGroup: UInt64,
         endGroup: UInt64,
         startObject: UInt64,
         endObject: UInt64,
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
                   endObject: endObject)
    }

    override func statusChanged(_ status: QSubscribeTrackHandlerStatus) {
        super.statusChanged(status)
        self.statusChanged?(status)
    }

    override func objectReceived(_ objectHeaders: QObjectHeaders, data: Data, extensions: [NSNumber: Data]?) {
        super.objectReceived(objectHeaders, data: data, extensions: extensions)
        self.objectReceived?(objectHeaders, data, extensions)
    }
}
