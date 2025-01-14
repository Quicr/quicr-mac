// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Represents a client-facing collection of logically related subscriptions,
/// containing one or more actual track subscriptions.
/// Implementing this interface with >1 handler is useful when data streams
/// across multiple subscribe handlers need to be compared or collated.
protocol SubscriptionSet: AnyObject {
    /// Identifier for this subscription set.
    var sourceId: SourceIDType { get }
    var participantId: ParticipantId { get }

    /// Get the subscribe track handlers for this subscription set.
    /// - Returns: The (one or more) subscribe track handlers for this subscription.
    func getHandlers() -> [FullTrackName: Subscription]

    /// Remove a handler for the given track name.
    /// - Parameter ftn: The full track name to lookup on.
    /// - Returns: The removed handler, if any.
    func removeHandler(_ ftn: FullTrackName) -> Subscription?

    /// Add a handler for the given track name to the set.
    /// - Parameter handler: The handler to add.
    /// - Throws: ``SubscriptionSetError/handlerExists`` if a handler for the same FTN exists.
    func addHandler(_ handler: Subscription) throws

    /// Should fire whenever a managed track handler changes it's status.
    func statusChanged(_ ftn: FullTrackName, status: QSubscribeTrackHandlerStatus)
}

import os

@Observable
class ObservableSubscriptionSet: SubscriptionSet {
    let sourceId: SourceIDType
    let participantId: ParticipantId
    private(set) var observedLiveSubscriptions: Set<FullTrackName> = []
    private var handlers: [FullTrackName: Subscription] = [:]
    private let handlersLock = OSAllocatedUnfairLock()

    init(sourceId: SourceIDType, participantId: ParticipantId) {
        self.sourceId = sourceId
        self.participantId = participantId
    }

    @MainActor
    internal func updateObserved(_ liveSubscriptions: Set<FullTrackName>) {
        self.observedLiveSubscriptions = liveSubscriptions
    }

    private func dispatchAdd(for ftn: FullTrackName) {
        Task(priority: .utility) {
            await MainActor.run {
                self.observedLiveSubscriptions.insert(ftn)
            }
        }
    }

    private func dispatchRemove(for ftn: FullTrackName) {
        Task(priority: .utility) {
            await MainActor.run {
                self.observedLiveSubscriptions.remove(ftn)
            }
        }
    }

    func getHandlers() -> [FullTrackName: Subscription] {
        self.handlersLock.withLock {
            self.handlers
        }
    }

    func removeHandler(_ ftn: FullTrackName) -> Subscription? {
        let removed = self.handlersLock.withLock {
            self.handlers.removeValue(forKey: ftn)
        }
        if removed != nil {
            self.dispatchRemove(for: ftn)
        }
        return removed
    }

    func addHandler(_ handler: Subscription) throws {
        let ftn = FullTrackName(handler.getFullTrackName())
        try self.handlersLock.withLock {
            guard self.handlers[ftn] == nil else {
                throw SubscriptionSetError.handlerExists
            }
            self.handlers[.init(handler.getFullTrackName())] = handler
        }
        self.dispatchAdd(for: ftn)
    }

    func statusChanged(_ ftn: FullTrackName, status: QSubscribeTrackHandlerStatus) {
        switch status {
        case .notSubscribed:
            _ = self.removeHandler(ftn)
        default:
            break
        }
    }
}
