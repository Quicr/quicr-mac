// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ObservableSubscriptionSetDetails: View {
    let observable: ObservableSubscriptionSet
    let manifestSubscriptionSet: ManifestSubscription
    let controller: MoqCallController
    let factory: SubscriptionFactory
    private let logger = DecimusLogger(ObservableSubscriptionSetDetails.self)

    var body: some View {
        let handlers = self.observable.getHandlers()
        // Quality subscribes.
        if !self.manifestSubscriptionSet.profileSet.profiles.isEmpty {
            GroupBox(self.observable.sourceId) {
                VStack {
                    ForEach(self.manifestSubscriptionSet.profileSet.profiles, id: \.namespace) { manifestSubscription in
                        if let manifestFtn = try? manifestSubscription.getFullTrackName() {
                            // Profile label.
                            Text(manifestSubscription.qualityProfile)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .frame(alignment: .leading)

                            // Toggle for subscribe state.
                            LabeledToggle("Subscribed",
                                          isOn: self.makeSubscribeBinding(manifestSubscription,
                                                                          manifestFtn: manifestFtn))

                            // Buffer inspection.
                            if let subscription = handlers[manifestFtn] {
                                if let subscription = subscription as? VideoSubscription {
                                    if let videoHandler = subscription.handler.get(),
                                       let buffer = videoHandler.jitterBuffer {
                                        HStack {
                                            Text("Current:")
                                            Spacer()
                                            HStack {
                                                Text(buffer.currentDepth * 1000,
                                                     format: .number.precision(.fractionLength(2)))
                                                Text("ms")
                                            }
                                        }
                                        HStack {
                                            Text("Target:")
                                            Spacer()
                                            HStack {
                                                Text(buffer.baseTargetDepth * 1000,
                                                     format: .number.precision(.fractionLength(2)))
                                                Text("ms")
                                            }
                                        }
                                    } else {
                                        Text("No handler yet")
                                    }
                                } else {
                                    Text("Only video subscriptions are supported")
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Text("Missing subscription")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
        } else {
            Text("No profiles available")
                .foregroundStyle(.secondary)
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
