// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct SubscriptionPopover: View {
    private let controller: MoqCallController
    private let manifest: Manifest
    private let factory: SubscriptionFactory

    class ViewModel: ObservableObject {}
    @ObservedObject private var model = ViewModel()

    init(_ controller: MoqCallController, manifest: Manifest, factory: SubscriptionFactory) {
        self.controller = controller
        self.manifest = manifest
        self.factory = factory
    }

    var body: some View {
        Text("Subscriptions")
            .font(.title)

        ForEach(self.manifest.subscriptions, id: \.sourceID) { manifestSubscriptionSet in
            if let set = self.controller.getSubscriptionSet(manifestSubscriptionSet.sourceID) {
                Text(manifestSubscriptionSet.sourceID)
                    .bold()
                let existing = self.controller.getSubscriptions(set)
                ForEach(manifestSubscriptionSet.profileSet.profiles, id: \.namespace) { manifestSubscription in
                    // Is this profile already subscribed to?
                    let exists: Bool = existing.contains(where: {
                        let ftn = FullTrackName($0.getFullTrackName())
                        let manifestFtn = try! manifestSubscription.getFullTrackName()
                        return ftn == manifestFtn
                    })
                    let binding = Binding<Bool>(get: {
                        exists
                    }, set: { isOn in
                        if isOn {
                            try! self.controller.subscribe(set: set, profile: manifestSubscription, factory: self.factory)
                        } else {
                            let ftn = try! manifestSubscription.getFullTrackName()
                            try! self.controller.unsubscribe(set.sourceId, ftn: ftn)
                        }
                        // Manually cause the view to refresh now we've changed the state.
                        self.model.objectWillChange.send()
                    })
                    LabeledToggle(manifestSubscription.qualityProfile,
                                  isOn: binding)
                }
            } else {
                Text(manifestSubscriptionSet.sourceID).foregroundStyle(.red)
            }
        }
    }
}
