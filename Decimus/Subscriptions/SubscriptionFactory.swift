import Foundation

// swiftlint:disable identifier_name
enum SubscriptionFactoryError: Error {
    case NoFactory
    case InvalidCodecConfig(Any)
}
// swiftlint:enable identifier_name

struct SubscriptionConfig: Codable {
    var jitterMax: UInt
    var jitterDepth: UInt
    var opusWindowSize: TimeInterval
    init() {
        jitterMax = 500
        jitterDepth = 60
        opusWindowSize = 0.01
    }
}

class SubscriptionFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             CodecConfig,
                                             MetricsSubmitter,
                                             ErrorWriter) throws -> Subscription?

    private lazy var factories: [CodecType: FactoryCallbackType] = [
        .h264: { [weak self] in
            guard let self = self else { throw SubscriptionFactoryError.NoFactory }
            guard let config = $1 as? VideoCodecConfig else {
                throw SubscriptionFactoryError.InvalidCodecConfig(type(of: $1))
            }
            return H264Subscription(namespace: $0,
                                    config: config,
                                    participants: self.participants,
                                    metricsSubmitter: $2,
                                    errorWriter: $3)
        },
        .opus: { [weak self] in
            guard let self = self else { throw SubscriptionFactoryError.NoFactory }
            guard let config = $1 as? AudioCodecConfig else {
                throw SubscriptionFactoryError.InvalidCodecConfig(type(of: $1))
            }
            return try OpusSubscription(namespace: $0,
                                        player: self.player,
                                        config: config,
                                        submitter: $2,
                                        errorWriter: $3,
                                        jitterDepth: self.config.jitterDepth,
                                        jitterMax: self.config.jitterMax,
                                        opusWindowSize: self.config.opusWindowSize)
        }
    ]

    private unowned let participants: VideoParticipants
    private unowned let player: FasterAVEngineAudioPlayer
    private let config: SubscriptionConfig
    init(participants: VideoParticipants, player: FasterAVEngineAudioPlayer, config: SubscriptionConfig) {
        self.participants = participants
        self.player = player
        self.config = config
    }

    func create(_ namespace: QuicrNamespace,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter,
                errorWriter: ErrorWriter) throws -> Subscription? {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        return try factory(namespace, config, metricsSubmitter, errorWriter)
    }
}
