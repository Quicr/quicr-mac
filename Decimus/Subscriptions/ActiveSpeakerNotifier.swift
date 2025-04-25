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
@Observable
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
    private let activeSpeakerStats: ActiveSpeakerStats?

    // For current state reporting.
    private(set) var lastRenderedSpeakers: OrderedSet<ParticipantId> = []
    private(set) var lastReceived: OrderedSet<ParticipantId> = []

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
         participantId: ParticipantId,
         activeSpeakerStats: ActiveSpeakerStats?) throws {
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
        self.activeSpeakerStats = activeSpeakerStats
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
        self.onActiveSpeakersChanged(self.lastSpeakers, real: false)
    }

    private func onActiveSpeakersChanged(_ speakers: OrderedSet<ParticipantId>, real: Bool = true) {
        self.logger.debug("[ActiveSpeakers] Changed: \(speakers)")

        // Report last received real active speaker list.
        if real {
            self.lastReceived = speakers
            if let stats = self.activeSpeakerStats {
                let now = Date.now
                Task(priority: .utility) {
                    for speaker in speakers {
                        await stats.activeSpeakerSet(speaker, when: now)
                    }
                }
            }
        }

        // Determine our rendering list.
        // We remove ourself, and then potentially clamp or expand the list
        // to match our desired count / layout.
        var speakers = speakers
        speakers.remove(self.participantId)
        self.lastSpeakers = speakers.union(self.lastSpeakers)
        speakers = self.count == nil ? speakers : OrderedSet(self.lastSpeakers.prefix(self.count!))

        // Report the last rendered list.
        self.lastRenderedSpeakers = speakers

        // Update slots.
        self.recheck(real: real, desiredSlots: speakers.count)
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func recheck(real: Bool, desiredSlots: Int) { // swiftlint:disable:this function_body_length
        var currentSlots = 0

        // How many current subscriptions are rendering?
        let existingSets = self.controller.getSubscriptionSets().filter { $0 is VideoSubscriptionSet }
        for set in existingSets {
            // swiftlint:disable:next line_length
            for case let handler as DisplayNotification in set.getHandlers().values where handler.getMediaState() == .rendered {
                currentSlots += 1
                break // 1 display per set is enough.
            }
        }

        // Firstly, subscribe to video from any speakers we are not already subscribed to.
        var subbed = 0
        let existingSubscriptions = existingSets.reduce(into: []) {
            $0.append(contentsOf: $1.getHandlers().compactMap { $0.value })
        }
        for set in self.videoSubscriptions where self.lastRenderedSpeakers.contains(set.participantId) {
            sets: for subscription in set.profileSet.profiles {
                do {
                    // We're only interested in non-existing subscriptions.
                    let ftn = try subscription.getFullTrackName()
                    guard !existingSubscriptions.contains(where: { FullTrackName($0.getFullTrackName()) == ftn }) else {
                        // Here we landed on an interested but already subscribed subscription.
                        // If they haven't rendered yet, they will fill a slot soon, recheck then.
                        for case let handler as DisplayNotification in existingSubscriptions {
                            guard handler.getMediaState() == .rendered else {
                                // Register to recheck when this goes live.
                                var token: Int?
                                token = handler.registerDisplayCallback { [weak self] in
                                    defer { handler.unregisterDisplayCallback(token!) }
                                    guard let self = self else { return }
                                    self.logger.info("Existing subscription just started displaying")
                                    self.recheck(real: real, desiredSlots: desiredSlots)
                                }
                                continue sets // We only care about 1/N displays.
                            }
                        }
                        continue sets // Nothing else to do.
                    }
                    // Subscribe.
                    subbed += 1
                    self.logger.debug(
                        "[ActiveSpeakers] Subscribing to: \(subscription.namespace) (\(set.participantId))")
                    // Does a set for this already exist?
                    // TODO: Clean this up.
                    let targetSet: SubscriptionSet
                    if let found = existingSets.filter({$0.sourceId == set.sourceID}).first {
                        targetSet = found
                    } else {
                        targetSet = try self.controller.subscribeToSet(details: set,
                                                                       factory: self.factory,
                                                                       subscribe: false)
                    }
                    let subscribed = try self.controller.subscribe(set: targetSet,
                                                                   profile: subscription,
                                                                   factory: self.factory)
                    guard let video = subscribed as? DisplayNotification else {
                        fatalError("Type contract mismatch")
                    }
                    var token: Int?
                    token = video.registerDisplayCallback { [weak self] in
                        defer { video.unregisterDisplayCallback(token!) }
                        guard let self = self else { return }
                        self.logger.debug("[ActiveSpeakers] Got display callback for: \(set.participantId)")
                        self.recheck(real: real, desiredSlots: desiredSlots)
                        self.logger.error("[ActiveSpeakers] Slots: \(currentSlots)/\(desiredSlots)")
                    }
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

        // If we have too many, unsubscribe until we don't.
        while currentSlots > desiredSlots {
            currentSlots -= self.unsubscribe(real: real)
        }
        self.logger.error("[ActiveSpeakers] Slots: \(currentSlots)/\(desiredSlots)")
    }

    private func unsubscribe(real: Bool) -> Int {
        // Unsubscribe from video for any speakers that are no longer active.
        let existing = self.controller.getSubscriptionSets()
        var unsubbed = 0
        for set in existing where !self.lastRenderedSpeakers.contains(set.participantId) {
            for handler in set.getHandlers().values where handler is T {
                // Unsubscribe.
                unsubbed += 1
                let ftn = FullTrackName(handler.getFullTrackName())
                self.logger.debug("[ActiveSpeakers] Unsubscribing from: \(ftn) (\(set.participantId)))")
                if real,
                   let stats = self.activeSpeakerStats {
                    Task(priority: .utility) {
                        await stats.remove(set.participantId, when: Date.now)
                    }
                }
                do {
                    try self.controller.unsubscribe(set.sourceId, ftn: ftn)
                } catch {
                    self.logger.warning("Error unsubscribing: \(error.localizedDescription)")
                }
            }

            // TODO: Should we break here?
            break
        }
        if unsubbed == 0 {
            self.logger.info("[ActiveSpeakers] No new unsubscribes needed")
        } else {
            self.logger.info("[ActiveSpeakers] Unsubscribed from \(unsubbed) subscriptions")
        }
        return unsubbed
    }
}
