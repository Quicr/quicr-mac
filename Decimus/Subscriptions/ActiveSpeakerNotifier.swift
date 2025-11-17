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
    private let pauseResume: Bool

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
         activeSpeakerStats: ActiveSpeakerStats?,
         pauseResume: Bool) throws {
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
        self.pauseResume = pauseResume
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
        self.logger.debug("[ActiveSpeakers] Changed: \(speakers). Real: \(real)")

        // Report last received real active speaker list.
        let now = Date.now
        if real {
            self.lastReceived = speakers
            if let stats = self.activeSpeakerStats {
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
        self.recheck(real: real, desiredSlots: speakers.count, when: now)
    }

    private func recheck(real: Bool, desiredSlots: Int, when: Date) {
        var currentSlots = 0

        // Get the sets we're interested in.
        let existingSets: [SourceIDType: VideoSubscriptionSet] = self.controller.getSubscriptionSets()
            .reduce(into: [:]) { dict, set in
                guard let set = set as? VideoSubscriptionSet else { return }
                dict[set.sourceId] = set
            }

        // Firstly, subscribe to video from any speakers we are not already subscribed to.
        for manifestSet in self.videoSubscriptions where self.lastRenderedSpeakers.contains(manifestSet.participantId) {
            // This set may already exist.
            let id = manifestSet.participantId
            guard existingSets[manifestSet.sourceID] == nil else {
                // We already have this set, what state is it in?
                let existingSet = existingSets[manifestSet.sourceID]!
                if self.pauseResume && existingSet.isPaused {
                    // If it's paused, it should be resumed.
                    existingSet.resume()
                }
                guard existingSet.getMediaState() != .rendered else {
                    // Already displaying, count it.
                    self.logger.debug("[ActiveSpeakers] Already displaying: \(id)")
                    currentSlots += 1
                    continue
                }

                // Otherwise, register a callback for when it does go live.
                var token: Int?
                self.logger.debug("[ActiveSpeakers] Register display callback for existing: \(id)")
                token = existingSet.registerDisplayCallback { [weak self] in
                    defer { existingSet.unregisterDisplayCallback(token!) }
                    guard let self = self else { return }
                    self.logger.debug("[ActiveSpeakers] Existing set just started displaying: \(id)")
                    self.recheck(real: real, desiredSlots: desiredSlots, when: when)
                }

                // Done with this set.
                continue
            }

            // This set doesn't exist.
            // We need to subscribe to all of its subscriptions and watch for display events.
            self.logger.debug("[ActiveSpeakers] Subscribing to: \(id)")
            guard let set = try? self.controller.subscribeToSet(details: manifestSet,
                                                                factory: self.factory,
                                                                subscribeType: .subscribe) else {
                self.logger.error("Couldn't subscribe to set")
                continue
            }

            guard let videoSet = set as? DisplayNotification else {
                fatalError("Type contract mismatch")
            }

            // Register interest in this set displaying.
            self.logger.debug("[ActiveSpeakers] Register display callback for new subscription: \(id)")
            var token: Int?
            token = videoSet.registerDisplayCallback { [weak self] in
                defer { videoSet.unregisterDisplayCallback(token!) }
                guard let self = self else { return }
                self.logger.debug("[ActiveSpeakers] Got display callback for: \(id)")
                let now = Date.now
                self.recheck(real: real, desiredSlots: desiredSlots, when: now)
            }
        }

        // Everything new is now setup. At this point, we should be rechecking our subscriptions from scratch.
        // If there are more active subscriptions than live subscriptions, we need to unsubscribe from them.
        let inPlay = self.pauseResume ? existingSets.filter { !$0.value.isPaused }.count : existingSets.count
        if inPlay > desiredSlots {
            // Remove one.
            self.unsubscribe(real: real, when: when)
            self.recheck(real: real, desiredSlots: desiredSlots, when: when)
            return
        }

        self.logger.debug("[ActiveSpeakers] Slots: \(currentSlots)/\(desiredSlots)")
    }

    private func unsubscribe(real: Bool, when: Date) {
        let filter: (any SubscriptionSet) -> Bool = {
            $0 is VideoSubscriptionSet && !self.lastRenderedSpeakers.contains($0.participantId)
        }
        let filterWithPause: (any SubscriptionSet) -> Bool = { !$0.isPaused && filter($0) }

        // Unsubscribe 1 video for any speakers that are no longer active.
        let existing = self.controller.getSubscriptionSets()
        if let toUnsub = existing
            .filter(self.pauseResume ? filterWithPause : filter)
            .sorted(by: { $0.participantId < $1.participantId })
            .first {
            if self.pauseResume {
                // Pause.
                self.logger.debug("[ActiveSpeakers] Pausing : \(toUnsub.participantId)")
                toUnsub.pause()
            } else {
                // Unsubscribe.
                do {
                    self.logger.debug("[ActiveSpeakers] Unsubscribing from: \(toUnsub.participantId)")
                    try self.controller.unsubscribeToSet(toUnsub.sourceId)
                    if let stats = self.activeSpeakerStats {
                        Task(priority: .utility) {
                            await stats.remove(toUnsub.participantId, when: when)
                        }
                    }
                } catch {
                    self.logger.error(
                        "Failed to unsubscribe from: \(toUnsub.participantId): \(error.localizedDescription)")
                }
            }
        }
    }
}

extension ParticipantId: Comparable {
    static func < (lhs: ParticipantId, rhs: ParticipantId) -> Bool {
        lhs.aggregate < rhs.aggregate
    }
}
