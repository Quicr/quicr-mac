import CoreMedia
import AVFoundation
import os

/// Possible errors raised by MoqCallController.
enum MoqCallControllerError: Error {
    /// Unexpected status during connection.
    case connectionFailure(QClientStatus)
    /// This functionality requires the controller to be connected.
    case notConnected
}

/// Represents a client-facing logical collection of subscriptions, containing one or more actual track subscriptions.
protocol Subscription {
    /// The (one or more) subscribe track handlers for this subscription.
    func getHandlers() -> [QSubscribeTrackHandlerObjC]
}

/// Controller for MoQ pub/sub.
class MoqCallController: QClientCallbacks {
    private let client: QClientObjC
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    private var publications: [FullTrackName: QPublishTrackHandlerObjC] = [:]
    private var subscriptions: [SourceIDType: Subscription] = [:]

    private let subscriptionConfig: SubscriptionConfig
    private let engine: DecimusAudioEngine
    private let granularMetrics: Bool
    private let videoParticipants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private var connected = false
    private let logger = DecimusLogger(MoqCallController.self)
    private let captureManager: CaptureManager

    init(config: QClientConfig,
         metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         subscriptionConfig: SubscriptionConfig,
         engine: DecimusAudioEngine,
         submitter: MetricsSubmitter?,
         granularMetrics: Bool,
         videoParticipants: VideoParticipants) {
        self.engine = engine
        self.subscriptionConfig = subscriptionConfig
        self.metricsSubmitter = submitter
        self.granularMetrics = granularMetrics
        self.videoParticipants = videoParticipants
        self.client = .init(config: config)
        self.captureManager = captureManager
        self.client.setCallbacks(self)
    }

    /// Connect to the relay.
    func connect() async throws {
        try await withCheckedThrowingContinuation(function: "CONNECT") { continuation in
            self.connectionContinuation = continuation
            let status = self.client.connect()
            switch status {
            case .clientConnecting:
                print("CLIENT CONNECTING")
                break
            case .ready:
                // This is here just for the type inference,
                // but we don't expect it to happen.
                assert(false)
                continuation.resume()
            default:
                continuation.resume(throwing: MoqCallControllerError.connectionFailure(status))
            }
        }
    }

    /// Inject a manifest into the controller, causing the creation of the corresponding publications and subscriptions
    /// and media objects.
    /// - Parameter manifest: The manifest to use.
    func setManifest(_ manifest: Manifest) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }

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
            let created = try pubFactory.create(publication: publication)
            for (namespace, handler) in created {
                self.publications[namespace] = handler
                self.client.publishTrack(withHandler: handler)
            }
        }

        // Create subscriptions.
        for manifestSubscription in manifest.subscriptions {
            let subscription = try self.create(subscription: manifestSubscription)
            self.subscriptions[manifestSubscription.sourceID] = subscription
            for handler in subscription.getHandlers() {
                self.client.subscribeTrack(withHandler: handler)
            }
        }
    }

    /// Disconnect from the relay.
    func disconnect() throws {
        let status = self.client.disconnect()
        guard status == .disconnecting else {
            throw MoqCallControllerError.connectionFailure(status)
        }
    }

    // MARK: Callbacks.

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
            print("We're connected")
        case .notReady:
            guard let connection = self.connectionContinuation else {
                fatalError("BAD")
            }
            self.connectionContinuation = nil
            self.connected = true
            connection.resume(throwing: MoqCallControllerError.connectionFailure(.notReady))
        default:
            self.logger.warning("Unhandled status change: \(status)")
        }
    }

    func serverSetupReceived(_ setup: QServerSetupAttributes) {
        self.logger.info("Got server setup received message")
    }

    func announceStatusChanged(_ namespace: Data, status: QPublishAnnounceStatus) {
        self.logger.info("Got announce status changed: \(status)")
    }

    private func create(subscription: ManifestSubscription) throws -> Subscription {
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
            return try VideoSubscription(subscription: subscription,
                                         participants: self.videoParticipants,
                                         metricsSubmitter: self.metricsSubmitter,
                                         videoBehaviour: self.subscriptionConfig.videoBehaviour,
                                         reliable: self.subscriptionConfig.mediaReliability.video.subscription,
                                         granularMetrics: self.granularMetrics,
                                         jitterBufferConfig: self.subscriptionConfig.videoJitterBuffer,
                                         simulreceive: self.subscriptionConfig.simulreceive,
                                         qualityMissThreshold: self.subscriptionConfig.qualityMissThreshold,
                                         pauseMissThreshold: self.subscriptionConfig.pauseMissThreshold,
                                         pauseResume: self.subscriptionConfig.pauseResume)
        }

        if found.isSubset(of: opusCodecs) {
            return try OpusSubscription(subscription: subscription,
                                        engine: self.engine,
                                        submitter: self.metricsSubmitter,
                                        jitterDepth: self.subscriptionConfig.jitterDepthTime,
                                        jitterMax: self.subscriptionConfig.jitterMaxTime,
                                        opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                        reliable: self.subscriptionConfig.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics)
        }

        throw CodecError.unsupportedCodecSet(found)
    }
}
