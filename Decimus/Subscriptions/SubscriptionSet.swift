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

    // Pause all subscriptions in this set.
    func pause()

    // Resume all subscriptions in this set.
    func resume()

    // Is the set paused?
    var isPaused: Bool { get }
}

import Synchronization

@Observable
class ObservableSubscriptionSet: SubscriptionSet {
    let sourceId: SourceIDType
    let participantId: ParticipantId
    private(set) var observedLiveSubscriptions: Set<FullTrackName> = []
    private let handlers = Mutex<[FullTrackName: Subscription]>([:])

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
        self.handlers.get()
    }

    func removeHandler(_ ftn: FullTrackName) -> Subscription? {
        let removed = self.handlers.withLock { $0.removeValue(forKey: ftn) }
        if removed != nil {
            self.dispatchRemove(for: ftn)
        }
        return removed
    }

    func addHandler(_ handler: Subscription) throws {
        let ftn = FullTrackName(handler.getFullTrackName())
        try self.handlers.withLock { handlers in
            guard handlers[ftn] == nil else {
                throw SubscriptionSetError.handlerExists
            }
            handlers[.init(handler.getFullTrackName())] = handler
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

    func pause() {
        for handler in self.handlers.get() {
            handler.value.pause()
        }
    }

    func resume() {
        for handler in self.handlers.get() {
            handler.value.resume()
        }
    }

    var isPaused: Bool {
        self.handlers.get().allSatisfy { $0.value.isPaused }
    }
}
