import Foundation

// swiftlint:disable identifier_name
enum SubscriptionFactoryError: Error {
    case NoFactory
    case InvalidCodecConfig(Any)
}
// swiftlint:enable identifier_name

enum VideoBehaviour: CaseIterable, Identifiable, Codable {
    case artifact
    case freeze
    var id: Self { self }
}

struct Reliability: Codable {
    var publication: Bool
    var subscription: Bool

    init(publication: Bool, subscription: Bool) {
        self.publication = publication
        self.subscription = subscription
    }

    init(both: Bool) {
        self.init(publication: both, subscription: both)
    }
}

struct MediaReliability: Codable {
    var audio: Reliability
    var video: Reliability

    init() {
        audio = .init(both: false)
        video = .init(both: true)
    }
}

struct SubscriptionConfig: Codable {
    var jitterMaxTime: TimeInterval
    var jitterDepthTime: TimeInterval
    var opusWindowSize: OpusWindowSize
    var videoBehaviour: VideoBehaviour
    var mediaReliability: MediaReliability
    var quicCwinMinimumKiB: UInt64
    var quicWifiShadowRttUs: TimeInterval
    var videoJitterBuffer: VideoJitterBuffer.Config
    var isSingleOrderedSub: Bool
    var isSingleOrderedPub: Bool
    var simulreceive: SimulreceiveMode
    var qualityMissThreshold: Int
    var pauseMissThreshold: Int
    var timeQueueTTL: Int
    var bitrateType: BitrateType
    var limit1s: Double
    var useResetWaitCC: Bool

    init() {
        jitterMaxTime = 0.5
        jitterDepthTime = 0.2
        opusWindowSize = .twentyMs
        videoBehaviour = .freeze
        mediaReliability = .init()
        quicCwinMinimumKiB = 128
        quicWifiShadowRttUs = 0.150
        videoJitterBuffer = .init(mode: .interval, minDepth: jitterDepthTime)
        isSingleOrderedSub = false
        isSingleOrderedPub = false
        simulreceive = .enable
        qualityMissThreshold = 3
        pauseMissThreshold = 30
        timeQueueTTL = 100
        bitrateType = .average
        limit1s = 2.5
        useResetWaitCC = true
    }
}

class SubscriptionFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             CodecConfig,
                                             MetricsSubmitter?) throws -> QSubscriptionDelegateObjC?

    private let participants: VideoParticipants
    private let engine: DecimusAudioEngine
    private let config: SubscriptionConfig
    private let granularMetrics: Bool
    private weak var controller: CallController?
    init(participants: VideoParticipants,
         engine: DecimusAudioEngine,
         config: SubscriptionConfig,
         granularMetrics: Bool,
         controller: CallController) {
        self.participants = participants
        self.engine = engine
        self.config = config
        self.granularMetrics = granularMetrics
        self.controller = controller
    }

    func create(_ sourceId: SourceIDType,
                profileSet: QClientProfileSet,
                metricsSubmitter: MetricsSubmitter?) throws -> QSubscriptionDelegateObjC? {
        // Supported codec sets.
        let videoCodecs: Set<CodecType> = [.h264, .hevc]
        let opusCodecs: Set<CodecType> = [.opus]

        // Resolve profile sets to config.
        var foundCodecs: [CodecType] = []
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile),
                                                      bitrateType: config.bitrateType,
                                                      limit1s: config.limit1s)
            foundCodecs.append(config.codec)
        }
        let found = Set(foundCodecs)

        if found.isSubset(of: videoCodecs) {
            let namegate: NameGate
            switch self.config.videoBehaviour {
            case .artifact:
                namegate = AllowAllNameGate()
            case .freeze:
                namegate = SequentialObjectBlockingNameGate()
            }

            return try VideoSubscription(sourceId: sourceId,
                                         profileSet: profileSet,
                                         participants: self.participants,
                                         metricsSubmitter: metricsSubmitter,
                                         namegate: namegate,
                                         reliable: self.config.mediaReliability.video.subscription,
                                         granularMetrics: self.granularMetrics,
                                         jitterBufferConfig: self.config.videoJitterBuffer,
                                         simulreceive: self.config.simulreceive,
                                         qualityMissThreshold: self.config.qualityMissThreshold,
                                         pauseMissThreshold: self.config.pauseMissThreshold,
                                         controller: self.controller)
        }

        if found.isSubset(of: opusCodecs) {
            return try OpusSubscription(sourceId: sourceId,
                                        profileSet: profileSet,
                                        engine: self.engine,
                                        submitter: metricsSubmitter,
                                        jitterDepth: self.config.jitterDepthTime,
                                        jitterMax: self.config.jitterMaxTime,
                                        opusWindowSize: self.config.opusWindowSize,
                                        reliable: self.config.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics)
        }

        throw CodecError.unsupportedCodecSet(found)
    }
}
