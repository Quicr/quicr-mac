// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ObservableSubscriptionSetDetails: View {
    var observable: ObservableSubscriptionSet
    let manifestSubscriptionSet: ManifestSubscription
    let controller: MoqCallController
    let factory: SubscriptionFactory
    let logger = DecimusLogger(ObservableSubscriptionSetDetails.self)

    var body: some View {
        // Set details.
        Text(self.observable.sourceId)
            .bold()

        // Ability to alter individual subscribe state via toggle.
        ForEach(manifestSubscriptionSet.profileSet.profiles, id: \.namespace) { manifestSubscription in
            if let manifestFtn = try? manifestSubscription.getFullTrackName() {
                let exists = self.observable.observedLiveSubscriptions.contains(manifestFtn)
                let binding = Binding<Bool>(get: {
                    exists
                }, set: { isOn in
                    if isOn {
                        do {
                            try self.controller.subscribe(set: self.observable,
                                                          profile: manifestSubscription,
                                                          factory: self.factory)
                        } catch {
                            self.logger.error("Failed to subscribe: \(error.localizedDescription)")
                        }
                    } else {
                        do {
                            try self.controller.unsubscribe(observable.sourceId, ftn: manifestFtn)
                        } catch {
                            self.logger.error("Failed to unsubscribe: \(error.localizedDescription)")
                        }
                    }
                })
                LabeledToggle(manifestSubscription.qualityProfile, isOn: binding)
            } else {
                Text("\(manifestSubscription.namespace.joined()) Failed to parse full track name")
                    .foregroundStyle(.red)
            }
        }
    }
}
