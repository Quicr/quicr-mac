import CoreMedia
import AVFoundation
import os

enum CallError: Error {
    case failedToConnect(Int32)
}

enum MoqCallControllerError: Error {
    case connectionFailure(QClientStatus)
    case notConnected
}

protocol Subscription {
    func getHandlers() -> [QSubscribeTrackHandlerObjC]
}

class MoqCallController: QClientCallbacks {
    private let client: QClientObjC
    private var connectionContinuation: CheckedContinuation<Void, Error>?

    private var publications: [QuicrNamespace: QPublishTrackHandlerObjC] = [:]
    private var subscriptions: [SourceIDType: Subscription] = [:]

    private let subscriptionConfig: SubscriptionConfig
    private let engine: DecimusAudioEngine
    private let granularMetrics: Bool
    private let videoParticipants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private var connected = false

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
        self.client.setCallbacks(self)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let status = self.client.connect()
            switch status {
            case .clientConnecting:
                self.connectionContinuation = continuation
            case .ready:
                continuation.resume()
            default:
                continuation.resume(throwing: MoqCallControllerError.connectionFailure(status))
            }
        }
    }

    func setManifest(_ manifest: Manifest) throws {
        guard self.connected else { throw MoqCallControllerError.notConnected }

        // Create publications and subscriptions.
        let pubFactory = PublicationFactory(opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                            reliability: self.subscriptionConfig.mediaReliability,
                                            engine: self.engine,
                                            granularMetrics: self.granularMetrics)
        for publication in manifest.publications {
            let created = try pubFactory.create(publication: publication)
            for (namespace, handler) in created {
                self.publications[namespace] = handler
                self.client.publishTrack(withHandler: handler)
            }
        }

        for manifestSubscription in manifest.subscriptions {
            let subscription = try self.create(subscription: manifestSubscription)
            self.subscriptions[manifestSubscription.sourceID] = subscription
            for handler in subscription.getHandlers() {
                self.client.subscribeTrack(withHandler: handler)
            }
        }
    }

    func disconnect() throws {
        let status = self.client.disconnect()
        guard status == .disconnecting else {
            throw MoqCallControllerError.connectionFailure(status)
        }
    }

    // MARK: Callbacks.

    func statusChanged(_ status: QClientStatus) {
        print("[MoqCallController] Status changed: \(status)")
        switch status {
        case .ready:
            guard let connection = connectionContinuation else {
                fatalError("BAD")
            }
            self.connectionContinuation = nil
            self.connected = true
            connection.resume()
        default:
            fatalError("")
        }
    }

    func serverSetupReceived(_ setup: QServerSetupAttributes) {
        print("Got server setup received message")
    }

    func announceStatusChanged(_ namespace: Data, status: QPublishAnnounceStatus) {
        print("Got announce status changed: \(status)")
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
            // Make an opus subscription object.
            print("Would have made an OpusSubscription")
        }

        throw CodecError.unsupportedCodecSet(found)
    }
}
