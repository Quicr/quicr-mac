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
    var hevcOverride: Bool
    var isSingleOrderedSub: Bool
    var isSingleOrderedPub: Bool
    var simulreceive: SimulreceiveMode
    var qualityMissThreshold: Int
    var timeQueueTTL: Int

    init() {
        jitterMaxTime = 0.5
        jitterDepthTime = 0.2
        opusWindowSize = .twentyMs
        videoBehaviour = .freeze
        mediaReliability = .init()
        quicCwinMinimumKiB = 128
        quicWifiShadowRttUs = 0.150
        videoJitterBuffer = .init()
        hevcOverride = false
        isSingleOrderedSub = true
        isSingleOrderedPub = false
        simulreceive = .none
        qualityMissThreshold = 3
        timeQueueTTL = 100
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
    init(participants: VideoParticipants,
         engine: DecimusAudioEngine,
         config: SubscriptionConfig,
         granularMetrics: Bool) {
        self.participants = participants
        self.engine = engine
        self.config = config
        self.granularMetrics = granularMetrics
    }

    func create(_ sourceId: SourceIDType,
                profileSet: QClientProfileSet,
                metricsSubmitter: MetricsSubmitter?) throws -> QSubscriptionDelegateObjC? {
        // TODO: This is sketchy.
        var codecType: CodecType?
        for profileIndex in 0..<profileSet.profilesCount {
            let profile = profileSet.profiles.advanced(by: profileIndex).pointee
            let config = CodecFactory.makeCodecConfig(from: .init(cString: profile.qualityProfile))
            if let codecType = codecType {
                assert(codecType == config.codec)
            } else {
                codecType = config.codec
            }
        }

        switch codecType {
        case .h264:
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
                                         hevcOverride: self.config.hevcOverride,
                                         simulreceive: self.config.simulreceive,
                                         qualityMissThreshold: self.config.qualityMissThreshold)
        case .opus:
            return try OpusSubscription(sourceId: sourceId,
                                        profileSet: profileSet,
                                        engine: self.engine,
                                        submitter: metricsSubmitter,
                                        jitterDepth: self.config.jitterDepthTime,
                                        jitterMax: self.config.jitterMaxTime,
                                        opusWindowSize: self.config.opusWindowSize,
                                        reliable: self.config.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics)
        default:
            throw CodecError.noCodecFound(codecType ?? .unknown)
        }
    }
}
