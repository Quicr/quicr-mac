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
    var videoJitterBuffer: VideoJitterBuffer.Config
    var isSingleOrderedSub: Bool
    var isSingleOrderedPub: Bool

    init() {
        jitterMaxTime = 0.5
        jitterDepthTime = 0.2
        opusWindowSize = .twentyMs
        videoBehaviour = .freeze
        mediaReliability = .init()
        quicCwinMinimumKiB = 128
        videoJitterBuffer = .init()
        isSingleOrderedSub = true
        isSingleOrderedPub = false
    }
}

class SubscriptionFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             CodecConfig,
                                             MetricsSubmitter?) throws -> Subscription?

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

    func create(_ namespace: QuicrNamespace,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?) throws -> Subscription? {

        switch config.codec {
        case .h264:
            guard let config = config as? VideoCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }

            let namegate: NameGate
            switch self.config.videoBehaviour {
            case .artifact:
                namegate = AllowAllNameGate()
            case .freeze:
                namegate = SequentialObjectBlockingNameGate()
            }

            return H264Subscription(namespace: namespace,
                                    config: config,
                                    participants: self.participants,
                                    metricsSubmitter: metricsSubmitter,
                                    namegate: namegate,
                                    reliable: self.config.mediaReliability.video.subscription,
                                    granularMetrics: self.granularMetrics,
                                    jitterBufferConfig: self.config.videoJitterBuffer)
        case .opus:
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            return try OpusSubscription(namespace: namespace,
                                        engine: self.engine,
                                        config: config,
                                        submitter: metricsSubmitter,
                                        jitterDepth: self.config.jitterDepthTime,
                                        jitterMax: self.config.jitterMaxTime,
                                        opusWindowSize: self.config.opusWindowSize,
                                        reliable: self.config.mediaReliability.audio.subscription,
                                        granularMetrics: self.granularMetrics)
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}
