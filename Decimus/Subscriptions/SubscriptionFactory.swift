// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import Foundation
import SFrame
import Synchronization

struct SFrameSettings: Codable {
    var enable: Bool
    var key: String

    init() {
        self.enable = false
        self.key = "sixteen byte key"
    }
}

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
    /// No more than this many packets will be concealed.
    var audioPlcLimit: Int
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
    /// SFrame encryption of media settings.
    var sframeSettings: SFrameSettings
    /// True to publish keyframe on subscribe update.
    var keyFrameOnUpdate: Bool
    /// Time to cleanup stale subscriptions for.
    var cleanupTime: TimeInterval
    /// Stream join time rules.
    var joinConfig: VideoSubscription.JoinConfig<TimeInterval>

    /// Create with default settings.
    init() {
        jitterMaxTime = 1
        jitterDepthTime = 0.2
        useNewJitterBuffer = false
        opusWindowSize = .twentyMs
        self.audioPlcLimit = 6
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
        self.sframeSettings = .init()
        stagger = true
        self.keyFrameOnUpdate = true
        self.cleanupTime = 1.5
        self.joinConfig = .init(fetchUpperThreshold: 1, newGroupUpperThreshold: 4)
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
                relayId: String) throws -> Subscription
}

class SubscriptionFactoryImpl: SubscriptionFactory {
    private let videoParticipants: VideoParticipants
    private let metricsSubmitter: MetricsSubmitter?
    private let subscriptionConfig: SubscriptionConfig
    private let granularMetrics: Bool
    private let engine: DecimusAudioEngine
    private let participantId: ParticipantId?
    private let joinDate: Date
    private let controller: MoqCallController
    private let verbose: Bool
    var activeSpeakerNotifier: ActiveSpeakerNotifierSubscription?
    private let activeSpeakerStats: ActiveSpeakerStats?
    private let startingGroup: UInt64?
    private let manualActiveSpeaker: Bool
    private let sframeContext: SFrameContext?

    init(videoParticipants: VideoParticipants,
         metricsSubmitter: MetricsSubmitter?,
         subscriptionConfig: SubscriptionConfig,
         granularMetrics: Bool,
         engine: DecimusAudioEngine,
         participantId: ParticipantId?,
         joinDate: Date,
         activeSpeakerStats: ActiveSpeakerStats?,
         controller: MoqCallController,
         verbose: Bool,
         startingGroup: UInt64?,
         manualActiveSpeaker: Bool,
         sframeContext: SFrameContext?) {
        self.videoParticipants = videoParticipants
        self.metricsSubmitter = metricsSubmitter
        self.subscriptionConfig = subscriptionConfig
        self.granularMetrics = granularMetrics
        self.engine = engine
        self.participantId = participantId
        self.joinDate = joinDate
        self.activeSpeakerStats = activeSpeakerStats
        self.controller = controller
        self.verbose = verbose
        self.startingGroup = startingGroup
        self.manualActiveSpeaker = manualActiveSpeaker
        self.sframeContext = sframeContext
    }

    func create(subscription: ManifestSubscription,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> any SubscriptionSet {
        let max = self.subscriptionConfig.useNewJitterBuffer ?
            self.subscriptionConfig.videoJitterBuffer.capacity :
            self.subscriptionConfig.jitterMaxTime
        if subscription.mediaType == ManifestMediaTypes.audio.rawValue && subscription.profileSet.type == "switched" {
            // This a switched / active speaker subscription type.
            return ActiveSpeakerSubscriptionSet(subscription: subscription,
                                                engine: self.engine,
                                                jitterDepth: self.subscriptionConfig.jitterDepthTime,
                                                jitterMax: max,
                                                opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                                ourParticipantId: self.participantId,
                                                submitter: self.metricsSubmitter,
                                                useNewJitterBuffer: self.subscriptionConfig.useNewJitterBuffer,
                                                granularMetrics: self.granularMetrics,
                                                activeSpeakerStats: self.activeSpeakerStats,
                                                maxPlcThreshold: self.subscriptionConfig.audioPlcLimit)
        }

        if subscription.mediaType == "playtime-control" {
            return ObservableSubscriptionSet(sourceId: subscription.sourceID, participantId: subscription.participantId)
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
                                            codecFactory: CodecFactoryImpl(),
                                            joinDate: self.joinDate,
                                            activeSpeakerStats: self.activeSpeakerStats,
                                            cleanupTime: self.subscriptionConfig.cleanupTime,
                                            slidingWindowTime: self.subscriptionConfig.videoJitterBuffer.window)
        }

        if found.isSubset(of: opusCodecs) {
            return ObservableSubscriptionSet(sourceId: subscription.sourceID, participantId: subscription.participantId)
        }

        throw CodecError.unsupportedCodecSet(found)
    }

    func create(set: SubscriptionSet,
                profile: Profile,
                codecFactory: CodecFactory,
                endpointId: String,
                relayId: String) throws -> Subscription {
        let ftn = try profile.getFullTrackName()
        // Ideally this wiring would be in CallController.
        let unregister: Subscription.StatusCallback = { [weak set] status in
            guard let set = set else { return }
            switch status {
            case .notSubscribed:
                _ = set.removeHandler(ftn)
            default:
                break
            }
        }

        if let set = set as? ActiveSpeakerSubscriptionSet {
            return try CallbackSubscription(profile: profile,
                                            endpointId: endpointId,
                                            relayId: relayId,
                                            metricsSubmitter: self.metricsSubmitter,
                                            priority: 0,
                                            groupOrder: .originalPublisherOrder,
                                            filterType: .latestObject,
                                            callback: { [weak set] in
                                                set?.receivedObject(headers: $0, data: $1, extensions: $2)
                                            },
                                            statusCallback: unregister)
        }

        if profile.qualityProfile == "playtime" {
            self.activeSpeakerNotifier = try ActiveSpeakerNotifierSubscription(profile: profile,
                                                                               endpointId: endpointId,
                                                                               relayId: relayId,
                                                                               submitter: self.metricsSubmitter,
                                                                               statusChanged: unregister)
            return self.activeSpeakerNotifier!
        }

        let config = codecFactory.makeCodecConfig(from: profile.qualityProfile, bitrateType: .average)
        if let videoConfig = config as? VideoCodecConfig {
            guard let set = set as? VideoSubscriptionSet else {
                throw "VideoConfig expects a VideoSubscriptionSet"
            }
            let ftn = try profile.getFullTrackName()
            let subConfig = self.subscriptionConfig
            let fetch = subConfig.joinConfig.fetchUpperThreshold * TimeInterval(videoConfig.fps)
            let newGroup = subConfig.joinConfig.newGroupUpperThreshold * TimeInterval(videoConfig.fps)
            let joinConfig = VideoSubscription.JoinConfig<UInt64>(fetchUpperThreshold: UInt64(fetch),
                                                                  newGroupUpperThreshold: UInt64(newGroup))
            return try VideoSubscription(profile: profile,
                                         config: videoConfig,
                                         participants: self.videoParticipants,
                                         metricsSubmitter: self.metricsSubmitter,
                                         videoBehaviour: subConfig.videoBehaviour,
                                         reliable: subConfig.mediaReliability.video.subscription,
                                         granularMetrics: self.granularMetrics,
                                         jitterBufferConfig: subConfig.videoJitterBuffer,
                                         simulreceive: subConfig.simulreceive,
                                         variances: set.decodedVariances,
                                         endpointId: endpointId,
                                         relayId: relayId,
                                         participantId: set.participantId,
                                         joinDate: self.joinDate,
                                         activeSpeakerStats: self.activeSpeakerStats,
                                         controller: self.controller,
                                         verbose: self.verbose,
                                         cleanupTime: subConfig.cleanupTime,
                                         subscriptionConfig: .init(joinConfig: joinConfig),
                                         sframeContext: self.sframeContext,
                                         callback: { [weak set] timestamp, when, cached, _, usable in
                                            guard let set = set else { return }
                                            set.receivedObject(ftn,
                                                               timestamp: timestamp,
                                                               when: when,
                                                               cached: cached,
                                                               usable: usable)
                                         },
                                         statusChanged: unregister)
        } else if config is AudioCodecConfig {
            guard set is ObservableSubscriptionSet else {
                throw "AudioCodecConfig expects ObservableSubscriptionSet"
            }
            let jitterMax = self.subscriptionConfig.useNewJitterBuffer ?
                self.subscriptionConfig.videoJitterBuffer.capacity :
                self.subscriptionConfig.jitterMaxTime
            return try OpusSubscription(profile: profile,
                                        engine: self.engine,
                                        submitter: self.metricsSubmitter,
                                        jitterDepth: self.subscriptionConfig.jitterDepthTime,
                                        jitterMax: jitterMax,
                                        opusWindowSize: self.subscriptionConfig.opusWindowSize,
                                        reliable: self.subscriptionConfig.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics,
                                        endpointId: endpointId,
                                        relayId: relayId,
                                        useNewJitterBuffer: self.subscriptionConfig.useNewJitterBuffer,
                                        cleanupTime: self.subscriptionConfig.cleanupTime,
                                        activeSpeakerStats: self.manualActiveSpeaker ? self.activeSpeakerStats : nil,
                                        sframeContext: self.sframeContext,
                                        maxPlcThreshold: self.subscriptionConfig.audioPlcLimit,
                                        statusChanged: unregister)
        }
        throw CodecError.invalidCodecConfig(config)
    }
}
