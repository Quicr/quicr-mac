// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

/// Possible errors raised by MoqCallController.
enum MoqCallControllerError: Error {
    /// Unexpected status during connection.
    case connectionFailure(QClientStatus)
    /// This functionality requires the controller to be connected.
    case notConnected
    /// No server message was received.
    case missingSetup
    /// The specified publication was not found.
    case publicationNotFound
    /// The specified subscription set was not found.
    case subscriptionSetNotFound
    /// The specified subscription was not found in the set.
    case subscriptionNotFound
}

enum SubscriptionSetError: Error {
    case handlerExists
}

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

/// Swift mapping for underlying client configuration.
struct ClientConfig {
    /// Moq URI for relay connection.
    let connectUri: String
    /// Local identifier for this client.
    let endpointUri: String
    /// In-depth transport configuration.
    let transportConfig: TransportConfig
    /// Interval at which to sample for metrics in milliseconds.
    let metricsSampleMs: UInt64
}

// TODO: Threading here needs to be checked.
// TODO: Possibly this can be an actor with non-isolated callbacks.

/// Decimus' interface to [`libquicr`](https://quicr.github.io/libquicr), managing
/// publish and subscribe track implementations and their creation from a manifest entry.
class MoqCallController: QClientCallbacks {
    // Dependencies.
    private let metricsSubmitter: MetricsSubmitter?
    private let measurement: MeasurementRegistration<MoqCallControllerMeasurement>?
    private let logger = DecimusLogger(MoqCallController.self)

    // State.
    private let client: MoqClient
    private let endpointUri: String
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var publications: [FullTrackName: QPublishTrackHandlerObjC] = [:]
    private var subscriptions: [SourceIDType: SubscriptionSet] = [:]
    private var connected = false
    private let callEnded: () -> Void

    /// The identifier of the connected server, or nil if not connected.
    public private(set) var serverId: String?

    /// Create a new controller.
    /// - Parameters:
    ///   - endpointUri: A unique identifier for this endpoint.
    ///   - client: An implementation of a MoQ client.
    ///   - submitter: Optionally, a submitter through which to submit metrics.
    ///   - callEnded: Closure to call when the call ends.
    init(endpointUri: String,
         client: MoqClient,
         submitter: MetricsSubmitter?,
         callEnded: @escaping () -> Void) {
        self.endpointUri = endpointUri
        self.client = client
        self.metricsSubmitter = submitter
        self.callEnded = callEnded
        if let metricsSubmitter = submitter {
            let measurement = MoqCallController.MoqCallControllerMeasurement(endpointId: endpointUri)
            self.measurement = .init(measurement: measurement, submitter: metricsSubmitter)
        } else {
            self.measurement = nil
        }
        self.client.setCallbacks(self)
    }

    deinit {
        self.logger.debug("Deinit")
    }

    /// Connect to the relay.
    /// - Throws: ``MoqCallControllerError/connectionFailure(_:)`` when an unexpected status is returned.
    func connect() async throws {
        try await withCheckedThrowingContinuation(function: "CONNECT") { continuation in
            self.connectionContinuation = continuation
            let status = self.client.connect()
            self.logger.debug("[MoqCallController] Connect => \(status)")
            switch status {
            case .clientConnecting:
                break
            case .clientPendingServerSetup:
                break
            case .ready:
                self.connected = true
                continuation.resume()
            default:
                if let connectionContinuation = self.connectionContinuation {
                    self.connected = false
                    connectionContinuation.resume(throwing: MoqCallControllerError.connectionFailure(status))
                }
            }
        }
    }

    /// Disconnect from the relay.
    /// - Throws: ``MoqCallControllerError/connectionFailure(_:)`` with unexpected status.
    func disconnect() throws {
        assert(Thread.isMainThread)
        for publication in self.publications {
            try self.unpublish(publication.key)
        }
        for set in self.subscriptions {
            try self.unsubscribeToSet(set.key)
        }
        let status = self.client.disconnect()
        guard status == .disconnecting else {
            throw MoqCallControllerError.connectionFailure(status)
        }
        self.logger.info("[MoqCallController] Disconnected")
        self.publications.removeAll()
        self.subscriptions.removeAll()
    }

    // MARK: Pub/Sub Modification APIs.

    /// Return the list of actively managed publications.
    /// - Returns: List of publish track handlers.
    public func getPublications() -> [QPublishTrackHandlerObjC] {
        Array(self.publications.values)
    }

    /// Setup a publication for a track.
    /// - Parameter details: The details for the publication from the manifest.
    /// - Parameter factory: Factory to create publication objects.
    /// - Parameter codecFactory: Turns a quality profile into a codec configuration.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected. Otherwise, error from factory.
    public func publish(details: ManifestPublication, factory: PublicationFactory, codecFactory: CodecFactory) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        let created = try factory.create(publication: details,
                                         codecFactory: codecFactory,
                                         endpointId: self.endpointUri,
                                         relayId: self.serverId!)
        for (namespace, handler) in created {
            self.publications[namespace] = handler
            self.client.publishTrack(withHandler: handler)
        }
    }

    /// Stop publishing to a track.
    /// - Parameter fullTrackName: The FTN to unpublish.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected.
    /// ``MoqCallControllerError/publicationNotFound`` if the track name does not match a publication.
    public func unpublish(_ fullTrackName: FullTrackName) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        guard let publication = self.publications.removeValue(forKey: fullTrackName) else {
            throw MoqCallControllerError.publicationNotFound
        }
        self.client.unpublishTrack(withHandler: publication)
    }

    /// Get a managed subscription set for the given source ID, if any.
    /// - Parameter sourceID: SourceID to lookup on.
    /// - Returns: The matching set, if any.
    public func getSubscriptionSet(_ sourceID: SourceIDType) -> SubscriptionSet? {
        self.subscriptions[sourceID]
    }

    /// Get all managed subscription sets.
    /// - Returns: List of all sets.
    public func getSubscriptionSets() -> [SubscriptionSet] {
        Array(self.subscriptions.values)
    }

    /// Get all active subscriptions in the given set.
    /// - Parameter set: The set to query.
    /// - Returns: List of active track handlers.
    public func getSubscriptions(_ set: SubscriptionSet) -> [QSubscribeTrackHandlerObjC] {
        return Array(set.getHandlers().values)
    }

    /// Subscribe to a logically related set of subscriptions.
    /// - Parameter details: The details of the subscription set.
    /// - Parameter factory: Factory to create subscription handlers from.
    /// - Parameter subscribe: True to actually subscribe to the contained handlers. False to create a placeholder set.
    /// - Returns: The created ``SubscriptionSet``.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected. Otherwise, error from factory.
    public func subscribeToSet(details: ManifestSubscription,
                               factory: SubscriptionFactory,
                               subscribe: Bool) throws -> SubscriptionSet {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        let set = try factory.create(subscription: details,
                                     codecFactory: CodecFactoryImpl(),
                                     endpointId: self.endpointUri,
                                     relayId: self.serverId!)
        if subscribe {
            for profile in details.profileSet.profiles {
                try self.subscribe(set: set, profile: profile, factory: factory)
            }
        }
        self.subscriptions[details.sourceID] = set
        return set
    }

    /// Subscribe to a specific track and add it to an existing subscription set.
    /// - Parameter set: The subscription set to add the track to.
    /// - Parameter profile: The profile to subscribe to.
    /// - Parameter factory: Factory to create subscription objects.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected. Otherwise, error from factory.
    func subscribe(set: SubscriptionSet, profile: Profile, factory: SubscriptionFactory) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        let subscription = try factory.create(set: set,
                                              profile: profile,
                                              codecFactory: CodecFactoryImpl(),
                                              endpointId: self.endpointUri,
                                              relayId: self.serverId!)
        try set.addHandler(subscription)
        self.client.subscribeTrack(withHandler: subscription)
    }

    /// Unsubscribe to an entire subscription set.
    /// - Parameter sourceID: The identifier of the subscription set.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected.
    /// ``MoqCallControllerError/subscriptionSetNotFound`` if source ID does not match a set.
    public func unsubscribeToSet(_ sourceID: SourceIDType) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        guard let subscription = self.subscriptions.removeValue(forKey: sourceID) else {
            throw MoqCallControllerError.subscriptionSetNotFound
        }
        for (_, handler) in subscription.getHandlers() {
            self.client.unsubscribeTrack(withHandler: handler)
        }
    }

    /// Unsubscribe to a specific track within a subscription set.
    /// - Parameter source: The identifier of the subscription set.
    /// - Parameter ftn: The full track name to unsubscribe.
    /// - Throws: ``MoqCallControllerError`` if the set or track is not found.
    public func unsubscribe(_ source: SourceIDType, ftn: FullTrackName) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        guard let set = self.subscriptions[source] else {
            throw MoqCallControllerError.subscriptionSetNotFound
        }
        guard let handler = set.removeHandler(ftn) else {
            throw MoqCallControllerError.subscriptionNotFound
        }
        self.client.unsubscribeTrack(withHandler: handler)
    }

    // MARK: Callbacks.

    /// quicr::Client callback for status change.
    /// - Parameter status: The new status.
    func statusChanged(_ status: QClientStatus) {
        self.logger.info("[MoqCallController] Status changed: \(status)")
        switch status {
        case .ready:
            // TODO: Fix this up.
            guard let connection = self.connectionContinuation else {
                print("Got ready when we already had ready!?")
                return
            }
            guard self.serverId != nil else {
                self.logger.error("Missing expected Server Setup on ready")
                connection.resume(throwing: MoqCallControllerError.missingSetup)
                self.connectionContinuation = nil
                return
            }
            self.connectionContinuation = nil
            self.connected = true
            connection.resume()
        case .notReady:
            guard let connectionContinuation = self.connectionContinuation else {
                self.logger.error("Missing expected continuation")
                return
            }
            self.connectionContinuation = nil
            self.connected = false
            connectionContinuation.resume(throwing: MoqCallControllerError.connectionFailure(.notReady))
        case .clientConnecting:
            break
        case .clientPendingServerSetup:
            assert(self.connectionContinuation != nil)
        case .clientNotConnected:
            self.connected = false
            guard let connection = self.connectionContinuation else {
                self.logger.error("Disconnected from relay")
                self.callEnded()
                return
            }
            self.connectionContinuation = nil
            connection.resume(throwing: MoqCallControllerError.connectionFailure(.clientNotConnected))
            return
        default:
            self.logger.warning("Unhandled status change: \(status)")
        }
    }

    /// quicr::Client serverSetupReceived event.
    /// - Parameter setup: The set setup attributes received with the event.
    func serverSetupReceived(_ setup: QServerSetupAttributes) {
        let serverId = String(cString: setup.server_id)
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.setRelayId(serverId)
            }
        }
        self.logger.debug("Got server setup received message from: \(serverId)")
        self.serverId = serverId
    }

    /// quicr::Client announcement status changed in response to a publishAnnounce()
    /// - Parameter namespace: The namespace the changed announcement was for.
    /// - Parameter status: The new status the announcement has.
    func announceStatusChanged(_ namespace: Data, status: QPublishAnnounceStatus) {
        self.logger.info("Got announce status changed: \(status)")
    }

    /// Create subscription tracks and owning object for a manifest entry.
    /// - Parameter subscription: The manifest entry detailing this set of related subscription tracks.
    /// - Parameter endpointId: This endpoints unique identifier (for metrics/correlation).
    /// - Parameter relayId: The identifier of the relay we are connecting to (for metrics/correlation).
    /// - Throws: ``CodecError/unsupportedCodecSet(_:)`` if unsupported media type.
    /// Other errors on failure to create client media subscription handlers.

    /// libquicr's metrics callback.
    /// - Parameter metrics: Object containing all metrics.
    func metricsSampled(_ metrics: QConnectionMetrics) {
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }

    /// Get all managed subscriptions originating from the given partiticpant.
    /// - Parameter participantId: The participant ID to query on.
    /// - Returns: List of subscription sets.
    func getSubscriptionsByParticipant(_ participantId: ParticipantId) throws -> [SubscriptionSet] {
        self.subscriptions.values.filter { $0.participantId == participantId }
    }
}
