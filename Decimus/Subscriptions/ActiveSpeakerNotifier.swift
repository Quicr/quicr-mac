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

    private func onActiveSpeakersChanged(_ speakers: [EndpointId]) {
        self.logger.debug("[ActiveSpeakers] Changed: \(speakers)")
        let existing = self.controller.getSubscriptionSets()

        // Firstly, unsubscribe from video for any speakers that are no longer active.
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
                    try self.controller.unsubscribe(set.sourceId, ftn: ftn)
                } catch {
                    self.logger.warning("Error getting endpoint ID: \(error)")
                }
            }
        }

        // Now, subscribe to video from any speakers we are not already subscribed to.
        for speaker in speakers {
            for set in self.manifest {
                for subscription in set.profileSet.profiles {
                    do {
                        // If this subscription is in existing, skip it.
                        let existingSources = existing.map { $0.sourceId }
                        let ftn = try subscription.getFullTrackName()
                        guard !existingSources.contains(set.sourceID),
                              let mediaType = UInt16(try ftn.getMediaType(), radix: 16),
                              mediaType & 0x80 != 0 else {
                            continue
                        }
                        let endpointId = try ftn.getEndpointId()
                        guard endpointId == speaker else { continue }
                        self.logger.debug("[ActiveSpeakers] Subscribing to: \(subscription.namespace) (\(endpointId))")
                        try self.controller.subscribeToSet(details: set, factory: self.factory)
                    } catch {
                        self.logger.error("Failed to subscribe: \(subscription.namespace)")
                    }
                }
            }
        }
    }
}
