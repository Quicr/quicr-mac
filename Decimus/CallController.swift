// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CoreMedia
import AVFoundation
import os

/// Possible errors raised by MoqCallController.
enum MoqCallControllerError: Error {
    /// Unexpected status during connection.
    case connectionFailure(QClientStatus)
    /// This functionality requires the controller to be connected.
    case notConnected
    /// No server message was received.
    case missingSetup
}

/// Represents a client-facing collection of logically related subscriptions,
/// containing one or more actual track subscriptions.
/// Implementing this interface with >1 handler is useful when data streams
/// across multiple subscribe handlers need to be compared or collated.
protocol SubscriptionSet {
    /// Get the subscribe track handlers for this subscription set.
    /// - Returns: The (one or more) subscribe track handlers for this subscription.
    func getHandlers() -> [QSubscribeTrackHandlerObjC]
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

/// Decimus' interface to [`libquicr`](https://quicr.github.io/libquicr), managing
/// publish and subscribe track implementations and their creation from a manifest entry.
class MoqCallController: QClientCallbacks {
    // Dependencies.
    private let subscriptionConfig: SubscriptionConfig
    private let engine: DecimusAudioEngine
    private let granularMetrics: Bool
    private let videoParticipants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let measurement: MeasurementRegistration<MoqCallControllerMeasurement>?
    private let logger = DecimusLogger(MoqCallController.self)
    private let captureManager: CaptureManager

    // State.
    private let client: QClientObjC
    private let config: ClientConfig
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var publications: [FullTrackName: QPublishTrackHandlerObjC] = [:]
    private var subscriptions: [SourceIDType: SubscriptionSet] = [:]
    private var connected = false
    private let callEnded: () -> Void
    var serverId: String?

    /// Create a new controller.
    /// - Parameters:
    ///   - config: Underlying `quicr::Client` config.
    ///   - captureManager: Video camera capture manager.
    ///   - subscriptionConfig: Application configuration for subscription creation.
    ///   - engine: Audio capture/playout engine.
    ///   - videoParticipants: Video rendering manager.
    ///   - submitter: Optionally, a submitter through which to submit metrics.
    ///   - granularMetrics: True to enable granular metrics, with a potential performance cost.
    init(config: ClientConfig,
         captureManager: CaptureManager,
         subscriptionConfig: SubscriptionConfig,
         engine: DecimusAudioEngine,
         videoParticipants: VideoParticipants,
         submitter: MetricsSubmitter?,
         granularMetrics: Bool,
         callEnded: @escaping () -> Void) {
        self.config = config
        self.client = config.connectUri.withCString { connectUri in
            config.endpointUri.withCString { endpointId in
                QClientObjC(config: .init(connectUri: connectUri,
                                          endpointId: endpointId,
                                          transportConfig: config.transportConfig,
                                          metricsSampleMs: config.metricsSampleMs))
            }
        }
        self.captureManager = captureManager
        self.subscriptionConfig = subscriptionConfig
        self.engine = engine
        self.videoParticipants = videoParticipants
        self.metricsSubmitter = submitter
        self.granularMetrics = granularMetrics
        self.callEnded = callEnded
        if let metricsSubmitter = submitter {
            let measurement = MoqCallController.MoqCallControllerMeasurement(endpointId: config.endpointUri)
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
            switch status {
            case .clientConnecting:
                break
            case .clientPendingServerSetup:
                break;
            case .ready:
                // This is here just for the type inference,
                // but we don't actually expect it to happen.
                assert(false)
                continuation.resume()

            default:
                continuation.resume(throwing: MoqCallControllerError.connectionFailure(status))
            }
        }
    }

    /// Inject a manifest into the controller.
    /// This causes the creation of the corresponding publications and subscriptions and media objects.
    /// This MUST be called after connecting.
    /// - Parameter manifest: The manifest to use.
    /// - Throws: ``MoqCallControllerError/notConnected`` if not yet connected.
    func setManifest(_ manifest: Manifest) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }
        guard let serverId = self.serverId else { throw MoqCallControllerError.missingSetup }

        // Create subscriptions.
        for manifestSubscription in manifest.subscriptions {
            let subscription = try self.create(subscription: manifestSubscription,
                                               endpointId: self.config.endpointUri,
                                               relayId: serverId)
            self.subscriptions[manifestSubscription.sourceID] = subscription
            for handler in subscription.getHandlers() {
                self.client.subscribeTrack(withHandler: handler)
            }
        }

        // Create publications.
        // TODO: We probably don't need a factory here. Just handle it internal to the controller.
        // TODO: If it gets bigger, we can extract.
        let pubFactory = PublicationFactory(opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                            reliability: self.subscriptionConfig.mediaReliability,
                                            engine: self.engine,
                                            metricsSubmitter: self.metricsSubmitter,
                                            granularMetrics: self.granularMetrics,
                                            captureManager: self.captureManager)
        for publication in manifest.publications {
            let created = try pubFactory.create(publication: publication,
                                                endpointId: self.config.endpointUri,
                                                relayId: serverId)
            for (namespace, handler) in created {
                self.publications[namespace] = handler
                self.client.publishTrack(withHandler: handler)
            }
        }
    }

    /// Disconnect from the relay.
    /// - Throws: ``MoqCallControllerError/connectionFailure(_:)`` with unexpected status.
    func disconnect() throws {
        for publication in self.publications {
            self.client.unpublishTrack(withHandler: publication.value)
        }
        for set in self.subscriptions {
            for subscription in set.value.getHandlers() {
                self.client.unsubscribeTrack(withHandler: subscription)
            }
        }
        let status = self.client.disconnect()
        guard status == .disconnecting else {
            throw MoqCallControllerError.connectionFailure(status)
        }
        self.logger.info("[MoqCallController] Disconnected")
        self.publications.removeAll()
        self.subscriptions.removeAll()
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
            self.connectionContinuation = nil
            self.connected = true
            connection.resume()
        case .notReady:
            guard let connection = self.connectionContinuation else {
                self.logger.error("Got notReady status when connection was nil")
                return
            }
            self.connectionContinuation = nil
            self.connected = true
            connection.resume(throwing: MoqCallControllerError.connectionFailure(.notReady))
        case .clientConnecting:
            assert(self.connectionContinuation != nil)
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
    private func create(subscription: ManifestSubscription,
                        endpointId: String,
                        relayId: String) throws -> SubscriptionSet {
        // Supported codec sets.
        let videoCodecs: Set<CodecType> = [.h264, .hevc]
        let opusCodecs: Set<CodecType> = [.opus]

        // Resolve profile sets to config.
        var foundCodecs: [CodecType] = []
        for profile in subscription.profileSet.profiles {
            let config = CodecFactory.makeCodecConfig(from: profile.qualityProfile,
                                                      bitrateType: self.subscriptionConfig.bitrateType)
            foundCodecs.append(config.codec)
        }
        let found = Set(foundCodecs)
        if found.isSubset(of: videoCodecs) {
            return try VideoSubscriptionSet(subscription: subscription,
                                            participants: self.videoParticipants,
                                            metricsSubmitter: self.metricsSubmitter,
                                            videoBehaviour: self.subscriptionConfig.videoBehaviour,
                                            reliable: self.subscriptionConfig.mediaReliability.video.subscription,
                                            granularMetrics: self.granularMetrics,
                                            jitterBufferConfig: self.subscriptionConfig.videoJitterBuffer,
                                            simulreceive: self.subscriptionConfig.simulreceive,
                                            qualityMissThreshold: self.subscriptionConfig.qualityMissThreshold,
                                            pauseMissThreshold: self.subscriptionConfig.pauseMissThreshold,
                                            pauseResume: self.subscriptionConfig.pauseResume,
                                            endpointId: endpointId,
                                            relayId: relayId)
        }

        if found.isSubset(of: opusCodecs) {
            return try OpusSubscription(subscription: subscription,
                                        engine: self.engine,
                                        submitter: self.metricsSubmitter,
                                        jitterDepth: self.subscriptionConfig.jitterDepthTime,
                                        jitterMax: self.subscriptionConfig.jitterMaxTime,
                                        opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                        reliable: self.subscriptionConfig.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics,
                                        endpointId: endpointId,
                                        relayId: relayId)
        }

        throw CodecError.unsupportedCodecSet(found)
    }

    /// libquicr's metrics callback.
    /// - Parameter metrics: Object containing all metrics.
    func metricsSampled(_ metrics: QConnectionMetrics) {
        if let measurement = self.measurement?.measurement {
            Task(priority: .utility) {
                await measurement.record(metrics)
            }
        }
    }
}
