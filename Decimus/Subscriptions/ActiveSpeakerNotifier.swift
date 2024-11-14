// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Identifies a participant across multiple tracks or media types.
typealias EndpointId = String

/// Provides a ranked list of active speakers via callback.
protocol ActiveSpeakerNotifier {
    typealias ActiveSpeakersChanged = ([EndpointId]) -> Void
    typealias CallbackToken = Int

    /// Register a callback to be notified when the active speakers change.
    /// - Parameter callback: The callback to be notified.
    /// - Returns: A token that can be used to unregister the callback
    func registerActiveSpeakerCallback(_ callback: @escaping ActiveSpeakersChanged) -> CallbackToken

    /// Unregister a previously registered callback.
    /// - Parameter token: The token returned by ``registerActiveSpeaker``
    func unregisterActiveSpeakerCallback(_ token: CallbackToken)
}

/// Manages the operations associated with active speaker changes.
class ActiveSpeakerApply {
    private let notifier: ActiveSpeakerNotifier
    private var callbackToken: ActiveSpeakerNotifier.CallbackToken?
    private let controller: MoqCallController
    private let manifest: [ManifestSubscription]
    private let factory: SubscriptionFactory
    private let logger = DecimusLogger(ActiveSpeakerApply.self)
    private var lastSpeakers: [EndpointId]?
    private var count: Int?

    /// Initialize the active speaker manager.
    /// - Parameters:
    ///  - notifier: Object providing active speaker updates.
    ///  - controller: Call controller managing subscriptions.
    ///  - subscriptions: Manifest of all available subscriptions.
    ///  - factory: Factory for subscription handler creation.
    init(notifier: ActiveSpeakerNotifier,
         controller: MoqCallController,
         subscriptions: [ManifestSubscription],
         factory: SubscriptionFactory) {
        self.notifier = notifier
        self.controller = controller
        self.manifest = subscriptions
        self.factory = factory
        self.callbackToken = self.notifier.registerActiveSpeakerCallback { [weak self] activeSpeakers in
            self?.onActiveSpeakersChanged(activeSpeakers)
        }
    }

    deinit {
        self.notifier.unregisterActiveSpeakerCallback(self.callbackToken!)
    }

    /// Set the number of active speakers to consider.
    /// - Parameter count: Subset of active speakers to consider, nil for all.
    func setClampCount(_ count: Int?) {
        self.logger.debug("[ActiveSpeakers] Set clamp count to: \(String(describing: count))")
        self.count = count
        guard let lastSpeakers = self.lastSpeakers else { return }
        self.onActiveSpeakersChanged(lastSpeakers)
    }

    private func onActiveSpeakersChanged(_ speakers: [EndpointId]) {
        self.logger.debug("[ActiveSpeakers] Changed: \(speakers)")
        self.lastSpeakers = speakers
        let speakers = self.count == nil ? speakers : Array(speakers.prefix(self.count!))
        let existing = self.controller.getSubscriptionSets()

        // Firstly, unsubscribe from video for any speakers that are no longer active.
        var unsubbed = false
        for set in existing {
            for handler in set.getHandlers().values {
                do {
                    let ftn = FullTrackName(handler.getFullTrackName())
                    let endpointId = try ftn.getEndpointId()
                    guard !speakers.contains(where: { $0 == endpointId }),
                          let mediaType = UInt16(try ftn.getMediaType(), radix: 16),
                          mediaType & 0x80 != 0 else {
                        continue
                    }
                    try self.logger.debug("[ActiveSpeakers] Unsubscribing from: \(ftn.getNamespace()) (\(endpointId))")
                    unsubbed = true
                    try self.controller.unsubscribe(set.sourceId, ftn: ftn)
                } catch {
                    self.logger.warning("Error getting endpoint ID: \(error)")
                }
            }
        }
        if !unsubbed {
            self.logger.debug("[ActiveSpeakers] No new unsubscribes needed")
        }

        // Now, subscribe to video from any speakers we are not already subscribed to.
        var subbed = false

        let existingHandlers = existing.reduce(into: []) { $0.append(contentsOf: $1.getHandlers().values) }
        for speaker in speakers {
            for set in self.manifest {
                for subscription in set.profileSet.profiles {
                    do {
                        let ftn = try FullTrackName(namespace: subscription.namespace, name: "")
                        guard !existingHandlers.contains(where: { FullTrackName($0.getFullTrackName()) == ftn }),
                              let mediaType = UInt16(try ftn.getMediaType(), radix: 16),
                              mediaType & 0x80 != 0 else {
                            continue
                        }
                        let endpointId = try ftn.getEndpointId()
                        guard endpointId == speaker else { continue }
                        self.logger.debug("[ActiveSpeakers] Subscribing to: \(subscription.namespace) (\(endpointId))")
                        // Does a set for this already exist?
                        // TODO: Clean this up.
                        let targetSet: SubscriptionSet
                        if let found = existing.filter({$0.sourceId == set.sourceID}).first {
                            targetSet = found
                        } else {
                            targetSet = try self.controller.subscribeToSet(details: set,
                                                                           factory: self.factory,
                                                                           subscribe: false)
                        }
                        try self.controller.subscribe(set: targetSet,
                                                      profile: subscription,
                                                      factory: self.factory)
                        subbed = true
                    } catch {
                        self.logger.error("Failed to subscribe: \(subscription.namespace)")
                    }
                }
            }
        }
        if !subbed {
            self.logger.debug("[ActiveSpeakers] No new subscribes needed")
        }
    }
}
