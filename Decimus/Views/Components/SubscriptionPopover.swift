// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct SubscriptionPopover: View {
    private let controller: MoqCallController
    private let manifest: Manifest
    private let factory: SubscriptionFactory
    private let simulreceive: SimulreceiveMode

    init(_ controller: MoqCallController, manifest: Manifest, factory: SubscriptionFactory, simulreceive: SimulreceiveMode) {
        self.controller = controller
        self.manifest = manifest
        self.factory = factory
        self.simulreceive = simulreceive
    }

    private var observables: [SourceIDType: ObservableSubscriptionSet] {
        let result: [SourceIDType: ObservableSubscriptionSet] = [:]
        return self.manifest.subscriptions.reduce(into: result) { partialResult, manifestSubscription in
            let set = self.controller.getSubscriptionSet(manifestSubscription.sourceID) as? ObservableSubscriptionSet
            partialResult[manifestSubscription.sourceID] = set
        }
    }

    var body: some View {
        VStack {
            Text("Subscriptions")
                .font(.title2)

            ScrollView {
                LazyVStack {
                    ForEach(self.manifest.subscriptions) { manifestSubscriptionSet in
                        if let set = self.observables[manifestSubscriptionSet.sourceID] {
                            ObservableSubscriptionSetDetails(observable: set,
                                                             manifestSubscriptionSet: manifestSubscriptionSet,
                                                             controller: self.controller,
                                                             factory: self.factory,
                                                             simulreceive: self.simulreceive)
                                .padding()
                        } else {
                            Text("\(manifestSubscriptionSet.sourceID) not observable").foregroundStyle(.red)
                        }
                    }
                }
            }
        }
    }
}
