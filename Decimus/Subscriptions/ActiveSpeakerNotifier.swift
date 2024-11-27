// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Provides a ranked list of active speakers via callback.
protocol ActiveSpeakerNotifier {
    typealias ActiveSpeakersChanged = ([ParticipantId]) -> Void
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
    private let codecFactory: CodecFactory
    private let logger = DecimusLogger(ActiveSpeakerApply.self)
    private var lastSpeakers: [ParticipantId]?
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
         factory: SubscriptionFactory,
         codecFactory: CodecFactory) {
        self.notifier = notifier
        self.controller = controller
        self.manifest = subscriptions
        self.factory = factory
        self.codecFactory = codecFactory
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
        guard let lastSpeakers = self.lastSpeakers else {
            self.logger.debug("[ActiveSpeakers] No set active speakers on clamp change")
            return
        }
        self.onActiveSpeakersChanged(lastSpeakers)
    }

    private func onActiveSpeakersChanged(_ speakers: [ParticipantId]) {
        self.logger.debug("[ActiveSpeakers] Changed: \(speakers)")
        self.lastSpeakers = speakers
        let speakers = self.count == nil ? speakers : Array(speakers.prefix(self.count!))
        let existing = self.controller.getSubscriptionSets()

        // Firstly, unsubscribe from video for any speakers that are no longer active.
        var unsubbed = false
        for set in existing {
            for handler in set.getHandlers().values {
                guard let handler = handler as? VideoSubscription,
                      !speakers.contains(where: { $0 == set.participantId }) else {
                    // Not interested in unsubscribing this.
                    continue
                }

                // Unsubscribe.
                let ftn = FullTrackName(handler.getFullTrackName())
                self.logger.debug("[ActiveSpeakers] Unsubscribing from: \(ftn) (\(set.participantId)))")
                do {
                    unsubbed = true
                    try self.controller.unsubscribe(set.sourceId, ftn: ftn)
                } catch {
                    self.logger.warning("Error unsubscribing: \(error.localizedDescription)")
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
                              let _ = self.codecFactory.makeCodecConfig(from: subscription.qualityProfile, bitrateType: .average) as? VideoCodecConfig,
                              set.participantId == speaker else {
                            // Not interested.
                            continue
                        }
                        // Subscribe.
                        subbed = true
                        self.logger.debug("[ActiveSpeakers] Subscribing to: \(subscription.namespace) (\(set.participantId))")
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
