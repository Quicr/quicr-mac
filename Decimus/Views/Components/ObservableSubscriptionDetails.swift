// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ObservableSubscriptionSetDetails: View {
    let observable: ObservableSubscriptionSet
    let manifestSubscriptionSet: ManifestSubscription
    let controller: MoqCallController
    let factory: SubscriptionFactory
    let logger = DecimusLogger(ObservableSubscriptionSetDetails.self)

    var body: some View {
        // Set details.
        Text(self.observable.sourceId)
            .bold()

        ForEach(self.manifestSubscriptionSet.profileSet.profiles, id: \.namespace) { manifestSubscription in
            Text(manifestSubscription.qualityProfile)
            if let manifestFtn = try? manifestSubscription.getFullTrackName() {
                // Toggle for subscribe state.
                Form {
                    LabeledToggle("Subscribed",
                                  isOn: self.makeSubscribeBinding(manifestSubscription, manifestFtn: manifestFtn))

                    // Get the actual state.
                    if let handler = self.observable.getHandlers().first {
                        if let video = handler.value as? VideoSubscription {
                            if let videoHandler = video.handler.get() {
                                if let buffer = videoHandler.jitterBuffer {
                                    Section("Jitter Buffer") {
                                        Text("Depth: \(buffer.currentDepth * 1000)ms")
                                        Text("Target: \(buffer.baseTargetDepth * 1000)ms")
                                    }
                                }
                            }
                        } else {
                            Text("I don't know what this is")
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Failed to lookup state")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                Text("\(manifestSubscription.namespace.joined()) Failed to parse full track name")
                    .foregroundStyle(.red)
            }
        }
    }

    private func makeSubscribeBinding(_ manifestSubscription: Profile, manifestFtn: FullTrackName) -> Binding<Bool> {
        let exists = self.observable.observedLiveSubscriptions.contains(manifestFtn)
        return .init(get: {
            exists
        }, set: { isOn in
            if isOn {
                do {
                    _ = try self.controller.subscribe(set: self.observable,
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
    }
}
