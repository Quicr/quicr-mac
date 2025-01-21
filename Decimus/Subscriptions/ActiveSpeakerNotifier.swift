// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import OrderedCollections

/// Provides a ranked list of active speakers via callback.
protocol ActiveSpeakerNotifier {
    typealias ActiveSpeakersChanged = (OrderedSet<ParticipantId>) -> Void
    typealias CallbackToken = Int

    /// Register a callback to be notified when the active speakers change.
    /// - Parameter callback: The callback to be notified.
    /// - Returns: A token that can be used to unregister the callback
    func registerActiveSpeakerCallback(_ callback: @escaping ActiveSpeakersChanged) -> CallbackToken

    /// Unregister a previously registered callback.
    /// - Parameter token: The token returned by ``registerActiveSpeaker``
    func unregisterActiveSpeakerCallback(_ token: CallbackToken)
}

enum ActiveSpeakerApplyError: Error {
    case videoOnly
}

/// Manages the operations associated with active speaker changes.
class ActiveSpeakerApply<T> where T: QSubscribeTrackHandlerObjC {
    private let notifier: ActiveSpeakerNotifier
    private var callbackToken: ActiveSpeakerNotifier.CallbackToken?
    private let controller: MoqCallController
    private let videoSubscriptions: [ManifestSubscription]
    private let factory: SubscriptionFactory
    private let logger = DecimusLogger(ActiveSpeakerApply.self)
    private var lastSpeakers: OrderedSet<ParticipantId>
    private var count: Int?
    private let participantId: ParticipantId

    /// Initialize the active speaker manager.
    /// - Parameters:
    ///  - notifier: Object providing active speaker updates.
    ///  - controller: Call controller managing subscriptions.
    ///  - subscriptions: Manifest of all available subscriptions.
    ///  - factory: Factory for subscription handler creation.
    ///  - participantId: Local participant ID.
    init(notifier: ActiveSpeakerNotifier,
         controller: MoqCallController,
         videoSubscriptions: [ManifestSubscription],
         factory: SubscriptionFactory,
         participantId: ParticipantId) throws {
        self.notifier = notifier
        self.controller = controller
        guard videoSubscriptions.allSatisfy({ $0.mediaType == ManifestMediaTypes.video.rawValue }) else {
            throw ActiveSpeakerApplyError.videoOnly
        }
        self.videoSubscriptions = videoSubscriptions
        self.factory = factory
        self.lastSpeakers = .init(videoSubscriptions.filter({$0.participantId != participantId})
                                    .map({$0.participantId}))
        self.participantId = participantId
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
        self.onActiveSpeakersChanged(lastSpeakers)
    }

    private func onActiveSpeakersChanged(_ speakers: OrderedSet<ParticipantId>) {
        self.logger.debug("[ActiveSpeakers] Changed: \(speakers)")
        var speakers = speakers
        speakers.remove(self.participantId)
        self.lastSpeakers = speakers.union(self.lastSpeakers)
        speakers = self.count == nil ? speakers : OrderedSet(self.lastSpeakers.prefix(self.count!))
        let existing = self.controller.getSubscriptionSets()

        // Firstly, subscribe to video from any speakers we are not already subscribed to.
        var subbed = 0
        let existingHandlers = existing.reduce(into: []) {
            $0.append(contentsOf: $1.getHandlers().compactMap { $0.value })
        }
        for set in self.videoSubscriptions where speakers.contains(set.participantId) {
            for subscription in set.profileSet.profiles {
                do {
                    // We're only interested in non-existing subscriptions.
                    let ftn = try subscription.getFullTrackName()
                    guard !existingHandlers.contains(where: { FullTrackName($0.getFullTrackName()) == ftn }) else {
                        continue
                    }
                    // Subscribe.
                    subbed += 1
                    self.logger.debug(
                        "[ActiveSpeakers] Subscribing to: \(subscription.namespace) (\(set.participantId))")
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
        if subbed == 0 {
            self.logger.info("[ActiveSpeakers] No new subscribes needed")
        } else {
            self.logger.info("[ActiveSpeakers] Subscribed to \(subbed) subscriptions")
        }

        // Now, unsubscribe from video for any speakers that are no longer active.
        var unsubbed = 0
        for set in existing where !speakers.contains(set.participantId) {
            for handler in set.getHandlers().values where handler is T {
                // Unsubscribe.
                unsubbed += 1
                let ftn = FullTrackName(handler.getFullTrackName())
                self.logger.debug("[ActiveSpeakers] Unsubscribing from: \(ftn) (\(set.participantId)))")
                do {
                    try self.controller.unsubscribe(set.sourceId, ftn: ftn)
                } catch {
                    self.logger.warning("Error unsubscribing: \(error.localizedDescription)")
                }
            }
        }
        if unsubbed == 0 {
            self.logger.info("[ActiveSpeakers] No new unsubscribes needed")
        } else {
            self.logger.info("[ActiveSpeakers] Unsubscribed from \(unsubbed) subscriptions")
        }
    }
}
