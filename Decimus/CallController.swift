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
    typealias PublishReceivedCallback = (_ connectionHandle: UInt64,
                                         _ requestId: UInt64,
                                         _ tfn: QFullTrackName,
                                         _ attributes: QPublishAttributes) -> Void

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
    private let callEnded: (() -> Void)?
    private let overrideNamespace: [String]?
    private let publishReceivedCallback: PublishReceivedCallback?

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
         overrideNamespace: [String]? = nil,
         publishReceived: PublishReceivedCallback? = nil,
         callEnded: (() -> Void)?) {
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
        self.overrideNamespace = overrideNamespace
        self.publishReceivedCallback = publishReceived
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
    /// - Returns: List of created ``(FullTrackName, QPublishTrackHandlerObjC)``.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected. Otherwise, error from factory.
    public func publish(details: ManifestPublication,
                        factory: PublicationFactory,
                        codecFactory: CodecFactory) throws -> [(FullTrackName, QPublishTrackHandlerObjC)] {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        let created = try factory.create(publication: details,
                                         codecFactory: codecFactory,
                                         endpointId: self.endpointUri,
                                         relayId: self.serverId!)
        for (namespace, handler) in created {
            self.publications[namespace] = handler
            self.client.publishTrack(withHandler: handler)
        }
        return created
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

    public func fetch(_ fetch: Fetch) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        self.client.fetchTrack(withHandler: fetch)
    }

    public func cancelFetch(_ fetch: Fetch) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        self.client.cancelFetchTrack(withHandler: fetch)
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
    public func getSubscriptions(_ set: SubscriptionSet) -> [Subscription] {
        return Array(set.getHandlers().values)
    }

    enum SubscribeType {
        case setOnly
        case subscribe
        case publisherInitiated(PublisherInitiatedDetails)
    }

    /// Subscribe to a logically related set of subscriptions.
    /// - Parameter details: The details of the subscription set.
    /// - Parameter factory: Factory to create subscription handlers from.
    /// - Parameter subscribe: True to actually subscribe to the contained handlers. False to create a placeholder set.
    /// - Parameter publisherInitiated: If publisher initiated, the details of that publish.
    /// - Returns: The created ``SubscriptionSet``.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected. Otherwise, error from factory.
    @discardableResult
    public func subscribeToSet(details: ManifestSubscription,
                               factory: SubscriptionFactory,
                               subscribeType: SubscribeType) throws -> SubscriptionSet {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        let set = try factory.create(subscription: details,
                                     codecFactory: CodecFactoryImpl(),
                                     endpointId: self.endpointUri,
                                     relayId: self.serverId!)

        // Determine what to do.
        let pubDetails: PublisherInitiatedDetails?
        let subscribe: Bool
        switch subscribeType {
        case .setOnly:
            pubDetails = nil
            subscribe = false
        case .subscribe:
            pubDetails = nil
            subscribe = true
        case .publisherInitiated(let value):
            pubDetails = value
            subscribe = true
        }

        if subscribe {
            var count = 0
            for profile in details.profileSet.profiles {
                let original = profile
                let profile: Profile
                if let overrideNamespace {
                    profile = original.transformNamespace(overrideNamespace: overrideNamespace,
                                                          sourceId: set.sourceId,
                                                          count: count)
                } else {
                    profile = original
                }

                do {
                    _ = try self.subscribe(set: set,
                                           profile: profile,
                                           factory: factory,
                                           publisherInitiated: pubDetails)
                    count += 1
                } catch let error as PubSubFactoryError {
                    self.logger.warning("[\(set.sourceId)] (\(profile.namespace)) Couldn't create subscription: " +
                                            "\(error.localizedDescription)",
                                        alert: true)
                }
            }
        }
        self.subscriptions[details.sourceID] = set
        return set
    }

    struct PublisherInitiatedDetails {
        let trackAlias: UInt64
        let requestId: UInt64
    }

    /// Subscribe to a specific track and add it to an existing subscription set.
    /// - Parameter set: The subscription set to add the track to.
    /// - Parameter profile: The profile to subscribe to.
    /// - Parameter factory: Factory to create subscription objects.
    /// - Returns: The created subscription.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected. Otherwise, error from factory.
    @discardableResult
    func subscribe(set: SubscriptionSet,
                   profile: Profile,
                   factory: SubscriptionFactory,
                   publisherInitiated: PublisherInitiatedDetails?) throws -> Subscription {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        let subscription = try factory.create(set: set,
                                              profile: profile,
                                              codecFactory: CodecFactoryImpl(),
                                              endpointId: self.endpointUri,
                                              relayId: self.serverId!,
                                              publisherInitiated: publisherInitiated != nil)
        if let publisherInitiated {
            subscription.setReceivedTrackAlias(publisherInitiated.trackAlias)
            subscription.setRequestId(publisherInitiated.requestId)
        }
        try set.addHandler(subscription)
        self.client.subscribeTrack(withHandler: subscription)
        return subscription
    }

    /// Directly subscribe to a handler.
    /// - Parameter: The handler to subscribe.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not connected.
    func subscribe(_ handler: Subscription) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        self.client.subscribeTrack(withHandler: handler)
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
                self.callEnded?()
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

    /// quicr::Client publish namespace status changed in response to a publishNamespace()
    /// - Parameter namespace: The namespace the changed publish was for.
    /// - Parameter status: The new status the publish has.
    func publishNamespaceStatusChanged(_ namespace: Data, status: QPublishNamespaceStatus) {
        self.logger.info("Got publish namespace status changed: \(status)")
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

    /// Publish received (subscribe namespace).
    func publishReceived(_ connectionHandle: UInt64,
                         requestId: UInt64,
                         tfn: any QFullTrackName,
                         attributes: QPublishAttributes) {
        self.publishReceivedCallback?(connectionHandle, requestId, tfn, attributes)
    }

    func resolvePublish(connectionHandle: UInt64,
                        requestId: UInt64,
                        attributes: QSubscribeAttributes,
                        response: QPublishResponse) {
        self.client.resolvePublish(connectionHandle, requestId: requestId, attributes: attributes, response: response)
    }

    func subscribeNamespace(_ prefix: [String]) {
        self.client.subscribeNamespace(prefix.map { .init($0.utf8) })
    }

    func subscribeNamespaceStatusChanged(_ tfn: [Data], errorCode: QSubscribeNamespaceErrorCode) {
        let namespace = tfn.compactMap { String(data: $0, encoding: .utf8) }
        self.logger.info("[\(namespace)] Subscribe namespace status changed: \(errorCode)")
    }
}

extension Profile {
    func transformNamespace(overrideNamespace: [String], sourceId: SourceIDType, count: Int) -> Profile {
        let namespace = overrideNamespace.map { $0.replacingOccurrences(of: CallState.namespaceSourcePlaceholder,
                                                                        with: sourceId) }
        let config = CodecFactoryImpl().makeCodecConfig(from: self.qualityProfile,
                                                        bitrateType: .average)
        let name = "\(config.codec)_\(count)"
        return .init(qualityProfile: self.qualityProfile,
                     expiry: self.expiry,
                     priorities: self.priorities,
                     namespace: namespace,
                     channel: self.channel,
                     name: name)
    }
}
