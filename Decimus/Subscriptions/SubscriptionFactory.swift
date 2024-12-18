// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation

/// Possible modes of rendering video.
enum VideoBehaviour: CaseIterable, Identifiable, Codable {
    /// Continue to feed frames even if there discontinuities, resulting in artifacts.
    case artifact
    /// Freeze the video on a discontinuity, resuming only on a new GOP.
    case freeze
    var id: Self { self }
}

/// Describes target reliable or unreliable transport mode for publications and subscriptions.
struct Reliability: Codable {
    /// Publication reliablility state.
    var publication: Bool
    /// Subscription reliability state.
    var subscription: Bool

    init(publication: Bool, subscription: Bool) {
        self.publication = publication
        self.subscription = subscription
    }

    init(both: Bool) {
        self.init(publication: both, subscription: both)
    }
}

/// Reliability structure breakout by media.
struct MediaReliability: Codable {
    /// Target reliability state for audio.
    var audio: Reliability
    /// Target reliability state for video.
    var video: Reliability

    init() {
        audio = .init(both: false)
        video = .init(both: true)
    }
}

/// Application configuration.
struct SubscriptionConfig: Codable {
    /// Audio max jitter depth.
    var jitterMaxTime: TimeInterval
    /// Audio target jitter depth.
    var jitterDepthTime: TimeInterval
    /// Use video jitter buffer for audio.
    var useNewJitterBuffer: Bool
    /// Opus encode/decode window size to use.
    var opusWindowSize: OpusWindowSize
    /// Control behaviour of video rendering.
    var videoBehaviour: VideoBehaviour
    /// Interval between key frames, or 0 for codec control.
    var keyFrameInterval: TimeInterval
    /// True to stagger video publications according to their quality.
    var stagger: Bool
    /// Describes target media reliability states.
    var mediaReliability: MediaReliability
    /// QUIC CWIN setting for underlying transport.
    var quicCwinMinimumKiB: UInt64
    /// Video jitter buffer mode and configuration.
    var videoJitterBuffer: JitterBuffer.Config
    /// True to only subscribe to the highest quality in a profile set.
    var isSingleOrderedSub: Bool
    /// True to only publish to the highest quality in a profile set.
    var isSingleOrderedPub: Bool
    /// Control simulreceive rendering.
    var simulreceive: SimulreceiveMode
    /// The number of frames to miss in a row before stepping down in quality.
    var qualityMissThreshold: Int
    /// The number of frames to miss in a row before pausing the subscription.
    var pauseMissThreshold: Int
    /// TTL for underlying libquicr time queue.
    var timeQueueTTL: Int
    /// If >0, set chunk size in libquicr.
    var chunkSize: UInt32
    /// Control encoder bitrate budgets.
    var bitrateType: BitrateType
    /// True to enable "reset & wait" functionality.
    var useResetWaitCC: Bool
    /// True to use BBR congestion control.
    var useBBR: Bool
    /// True to emit a qlog at the end of the call into Downloads or Documents.
    var enableQlog: Bool
    /// True to enable pause/resume behaviour.
    var pauseResume: Bool
    /// True to callback libquicr logs into unified logger (possible performance hit).
    var quicrLogs: Bool
    /// Override picoquic pacing for priorities.
    var quicPriorityLimit: UInt8
    /// True to enable SFrame encryption of media.
    var doSFrame: Bool

    /// Create with default settings.
    init() {
        jitterMaxTime = 0.2
        jitterDepthTime = 0.2
        useNewJitterBuffer = false
        opusWindowSize = .twentyMs
        videoBehaviour = .freeze
        keyFrameInterval = 5
        mediaReliability = .init()
        quicCwinMinimumKiB = 8
        videoJitterBuffer = .init(mode: .interval, minDepth: jitterDepthTime)
        isSingleOrderedSub = false
        isSingleOrderedPub = false
        simulreceive = .enable
        qualityMissThreshold = 3
        pauseMissThreshold = 30
        timeQueueTTL = 500
        chunkSize = 3000
        bitrateType = .average
        useResetWaitCC = false
        useBBR = true
        enableQlog = false
        pauseResume = false
        quicrLogs = false
        quicPriorityLimit = 0
        doSFrame = true
        stagger = true
    }
}

protocol SubscriptionFactory {
    func create(subscription: ManifestSubscription,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> SubscriptionSet

    func create(set: SubscriptionSet,
                profile: Profile,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> QSubscribeTrackHandlerObjC
}

class SubscriptionFactoryImpl: SubscriptionFactory {
    private let videoParticipants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let subscriptionConfig: SubscriptionConfig
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private let participantId: ParticipantId?
    var activeSpeakerNotifier: ActiveSpeakerNotifierSubscriptionSet?

    init(videoParticipants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         subscriptionConfig: SubscriptionConfig,
         granularMetrics: Bool,
         engine: DecimusAudioEngine,
         participantId: ParticipantId?) {
        self.videoParticipants = videoParticipants
        self.metricsSubmitter = metricsSubmitter
        self.subscriptionConfig = subscriptionConfig
        self.granularMetrics = granularMetrics
        self.engine = engine
        self.participantId = participantId
    }

    func create(subscription: ManifestSubscription, codecFactory: CodecFactory, endpointId: String, relayId: String) throws -> any SubscriptionSet {
        if subscription.mediaType == ManifestMediaTypes.audio.rawValue && subscription.profileSet.type == "switched" {
            // This a switched / active speaker subscription type.
            return ActiveSpeakerSubscriptionSet(subscription: subscription,
                                                engine: self.engine,
                                                jitterDepth: self.subscriptionConfig.jitterDepthTime,
                                                jitterMax: self.subscriptionConfig.jitterMaxTime,
                                                opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                                ourParticipantId: self.participantId)
        }

        if subscription.mediaType == "playtime-control" {
            let notifier = try ActiveSpeakerNotifierSubscriptionSet(subscription: subscription)
            self.activeSpeakerNotifier = notifier
            return notifier
        }

        // Supported codec sets.
        let videoCodecs: Set<CodecType> = [.h264, .hevc]
        let opusCodecs: Set<CodecType> = [.opus]

        // Resolve profile sets to config.
        var foundCodecs: [CodecType] = []
        for profile in subscription.profileSet.profiles {
            let config = codecFactory.makeCodecConfig(from: profile.qualityProfile,
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
                                            relayId: relayId,
                                            codecFactory: CodecFactoryImpl())
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
                                        relayId: relayId,
                                        useNewJitterBuffer: self.subscriptionConfig.useNewJitterBuffer)
        }

        throw CodecError.unsupportedCodecSet(found)
    }

    func create(set: SubscriptionSet, profile: Profile, codecFactory: CodecFactory, endpointId: String, relayId: String) throws -> QSubscribeTrackHandlerObjC {
        if let set = set as? ActiveSpeakerSubscriptionSet {
            return try CallbackSubscription(fullTrackName: profile.getFullTrackName(),
                                            priority: 0,
                                            groupOrder: .originalPublisherOrder,
                                            filterType: .latestGroup) { [weak set] in
                set?.receivedObject(headers: $0, data: $1, extensions: $2)
            }
        }

        if let set = set as? ActiveSpeakerNotifierSubscriptionSet {
            return set
        }

        let config = codecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
        if let videoConfig = config as? VideoCodecConfig {
            let set = set as! VideoSubscriptionSet
            let ftn = try profile.getFullTrackName()
            return try VideoSubscription(profile: profile,
                                         config: videoConfig,
                                         participants: self.videoParticipants,
                                         metricsSubmitter: self.metricsSubmitter,
                                         videoBehaviour: self.subscriptionConfig.videoBehaviour,
                                         reliable: self.subscriptionConfig.mediaReliability.video.subscription,
                                         granularMetrics: self.granularMetrics,
                                         jitterBufferConfig: self.subscriptionConfig.videoJitterBuffer,
                                         simulreceive: self.subscriptionConfig.simulreceive,
                                         variances: set.decodedVariances,
                                         endpointId: endpointId,
                                         relayId: relayId,
                                         participantId: set.participantId,
                                         callback: { [weak set] ts, when in
                                            guard let set = set else { return }
                                            set.receivedObject(ftn, timestamp: ts, when: when)
                                         },
                                         statusChanged: { [weak set] status in
                                            guard let set = set else { return }
                                            set.statusChanged(ftn, status: status)
                                         })
        } else if config as? AudioCodecConfig != nil {
            let set = set as! OpusSubscription
            return set
        }
        throw CodecError.invalidCodecConfig(config)
    }
}
