// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Represents a client-facing collection of logically related subscriptions,
/// containing one or more actual track subscriptions.
/// Implementing this interface with >1 handler is useful when data streams
/// across multiple subscribe handlers need to be compared or collated.
protocol SubscriptionSet {
    /// Identifier for this subscription set.
    var sourceId: SourceIDType { get }
    var participantId: ParticipantId { get }

    /// Get the subscribe track handlers for this subscription set.
    /// - Returns: The (one or more) subscribe track handlers for this subscription.
    func getHandlers() -> [FullTrackName: QSubscribeTrackHandlerObjC]

    /// Remove a handler for the given track name.
    /// - Parameter ftn: The full track name to lookup on.
    /// - Returns: The removed handler, if any.
    func removeHandler(_ ftn: FullTrackName) -> QSubscribeTrackHandlerObjC?

    /// Add a handler for the given track name to the set.
    /// - Parameter handler: The handler to add.
    /// - Throws: ``SubscriptionSetError/handlerExists`` if a handler for the same FTN exists.
    func addHandler(_ handler: QSubscribeTrackHandlerObjC) throws
}

@Observable
class ObservableSubscriptionSet: SubscriptionSet {
    let sourceId: SourceIDType
    let participantId: ParticipantId
    var observedLiveSubscriptions: Set<FullTrackName> = []

    init(sourceId: SourceIDType, participantId: ParticipantId) {
        self.sourceId = sourceId
        self.participantId = participantId
    }

    @MainActor
    internal func updateObserved(_ liveSubscriptions: Set<FullTrackName>) {
        self.observedLiveSubscriptions = liveSubscriptions
    }

    func getHandlers() -> [FullTrackName: QSubscribeTrackHandlerObjC] { [:] }
    func removeHandler(_ ftn: FullTrackName) -> QSubscribeTrackHandlerObjC? { nil }
    func addHandler(_ handler: QSubscribeTrackHandlerObjC) throws {}
}
