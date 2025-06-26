// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct SubscriptionPopover: View {
    private let controller: MoqCallController
    private let manifest: Manifest
    private let factory: SubscriptionFactory

    init(_ controller: MoqCallController, manifest: Manifest, factory: SubscriptionFactory) {
        self.controller = controller
        self.manifest = manifest
        self.factory = factory
    }

    var body: some View {
        Text("Subscriptions")
            .font(.title)

        // Get the observable sets.
        let result: [SourceIDType: ObservableSubscriptionSet] = [:]
        let observables = self.manifest.subscriptions.reduce(into: result) { partialResult, manifestSubscription in
            let set = self.controller.getSubscriptionSet(manifestSubscription.sourceID) as? ObservableSubscriptionSet
            partialResult[manifestSubscription.sourceID] = set
        }

        ForEach(self.manifest.subscriptions, id: \.sourceID) { manifestSubscriptionSet in
            if let set = observables[manifestSubscriptionSet.sourceID] {
                ObservableSubscriptionSetDetails(observable: set,
                                                 manifestSubscriptionSet: manifestSubscriptionSet,
                                                 controller: self.controller,
                                                 factory: self.factory)
            } else {
                Text("\(manifestSubscriptionSet.sourceID) not observable").foregroundStyle(.red)
            }
        }
    }
}
