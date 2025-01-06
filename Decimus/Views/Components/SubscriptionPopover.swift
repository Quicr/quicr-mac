// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUICore

struct SubscriptionPopover: View {
    private let controller: MoqCallController
    private let manifest: Manifest
    private let factory: SubscriptionFactory

    class ViewModel: ObservableObject {}
    @ObservedObject private var model = ViewModel()
    @State private var error: String?

    init(_ controller: MoqCallController, manifest: Manifest, factory: SubscriptionFactory) {
        self.controller = controller
        self.manifest = manifest
        self.factory = factory
    }

    var body: some View {
        Text("Subscriptions")
            .font(.title)

        if let error = self.error {
            Text(error).foregroundStyle(.red)
        }

        ForEach(self.manifest.subscriptions, id: \.sourceID) { manifestSubscriptionSet in
            if let set = self.controller.getSubscriptionSet(manifestSubscriptionSet.sourceID) {
                Text(manifestSubscriptionSet.sourceID)
                    .bold()
                let existing = self.controller.getSubscriptions(set)
                ForEach(manifestSubscriptionSet.profileSet.profiles, id: \.namespace) { manifestSubscription in
                    // Is this profile already subscribed to?
                    let exists = existing.contains(where: {
                        let ftn = FullTrackName($0.getFullTrackName())
                        let manifestFtn: FullTrackName
                        do {
                            manifestFtn = try manifestSubscription.getFullTrackName()
                        } catch {
                            self.dispatchError("Failed to get FullTrackName: \(error.localizedDescription)")
                            return false
                        }
                        return ftn == manifestFtn
                    })
                    let binding = Binding<Bool>(get: {
                        exists
                    }, set: { isOn in
                        if isOn {
                            do {
                                try self.controller.subscribe(set: set,
                                                              profile: manifestSubscription,
                                                              factory: self.factory)
                                self.dispatchError(nil)
                            } catch {
                                self.dispatchError("Failed to subscribe: \(error.localizedDescription)")
                            }
                        } else {
                            let ftn: FullTrackName
                            do {
                                ftn = try manifestSubscription.getFullTrackName()
                                self.dispatchError(nil)
                            } catch {
                                self.dispatchError("Failed to get FullTrackName: \(error.localizedDescription)")
                                return
                            }
                            do {
                                try self.controller.unsubscribe(set.sourceId, ftn: ftn)
                                self.dispatchError(nil)
                            } catch {
                                self.dispatchError("Failed to unsubscribe: \(error.localizedDescription)")
                            }
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

    // TODO: This is hack. Observer pattern will replace this.
    private func dispatchError(_ message: String?) {
        DispatchQueue.main.async {
            self.error = nil
        }
    }
}
