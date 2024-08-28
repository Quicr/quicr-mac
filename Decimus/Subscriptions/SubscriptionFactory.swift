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
    var simulreceive: SimulreceiveMode
    var qualityMissThreshold: Int
    var pauseMissThreshold: Int
    var timeQueueTTL: Int
    var chunkSize: UInt32
    var bitrateType: BitrateType
    var useResetWaitCC: Bool
    var useBBR: Bool
    var enableQlog: Bool
    var pauseResume: Bool
    var quicrLogs: Bool
    var quicPriorityLimit: UInt8
    var doSFrame: Bool

    init() {
        jitterMaxTime = 0.2
        jitterDepthTime = 0.2
        opusWindowSize = .twentyMs
        videoBehaviour = .freeze
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
    }
}

enum FullTrackNameError: Error {
    case parseError
}

struct FullTrackName: Hashable {
    let namespace: Data
    let name: Data

    init(namespace: String, name: String) throws {
        guard let namespace = namespace.data(using: .ascii) else {
            throw FullTrackNameError.parseError
        }
        self.namespace = namespace
        guard let name = name.data(using: .ascii) else {
            throw FullTrackNameError.parseError
        }
        self.name = name
    }

    func getNamespace() throws -> String {
        guard let namespace = String(data: self.namespace, encoding: .ascii) else {
            throw FullTrackNameError.parseError
        }
        return namespace
    }

    func getName() throws -> String {
        guard let name = String(data: self.name, encoding: .ascii) else {
            throw FullTrackNameError.parseError
        }
        return name
    }
}

//protocol Subscription {
//    
//}
//
//protocol Subscription {
//    var trackHandlers: [FullTrackName: QSubscribeTrackHandlerObjC] { get }
//}

class SubscriptionFactory {
    private let participants: VideoParticipants
    private let engine: DecimusAudioEngine
    private let config: SubscriptionConfig
    private let submitter: MetricsSubmitter
    private let granularMetrics: Bool

    init(participants: VideoParticipants,
         engine: DecimusAudioEngine,
         config: SubscriptionConfig,
         submitter: MetricsSubmitter,
         granularMetrics: Bool) {
        self.participants = participants
        self.engine = engine
        self.config = config
        self.submitter = submitter
        self.granularMetrics = granularMetrics
    }

    func create(subscription: ManifestSubscription) throws -> Subscription {
        // Supported codec sets.
        let videoCodecs: Set<CodecType> = [.h264, .hevc]
        let opusCodecs: Set<CodecType> = [.opus]

        // Resolve profile sets to config.
        var foundCodecs: [CodecType] = []
        for profile in subscription.profileSet.profiles {
            let config = CodecFactory.makeCodecConfig(from: profile.qualityProfile,
                                                      bitrateType: config.bitrateType)
            foundCodecs.append(config.codec)
        }
        let found = Set(foundCodecs)
        if found.isSubset(of: videoCodecs) {
            return try VideoSubscription(subscription: subscription,
                                         participants: self.participants,
                                         metricsSubmitter: self.submitter,
                                         videoBehaviour: self.config.videoBehaviour,
                                         reliable: self.config.mediaReliability.video.subscription,
                                         granularMetrics: self.granularMetrics,
                                         jitterBufferConfig: self.config.videoJitterBuffer,
                                         simulreceive: self.config.simulreceive,
                                         qualityMissThreshold: self.config.qualityMissThreshold,
                                         pauseMissThreshold: self.config.pauseMissThreshold,
                                         pauseResume: self.config.pauseResume)
        }

        if found.isSubset(of: opusCodecs) {
            // Make an opus subscription object.
        }

        throw CodecError.unsupportedCodecSet(found)
    }
}
