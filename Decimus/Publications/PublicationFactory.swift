import Foundation
import AVFAudio

class PublicationFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             QPublishObjectDelegateObjC,
                                             SourceIDType,
                                             CodecConfig,
                                             MetricsSubmitter?) throws -> Publication

    private let opusWindowSize: OpusWindowSize
    private let reliability: MediaReliability
    private let granularMetrics: Bool
    private unowned let engine: AudioEngine

    init(opusWindowSize: OpusWindowSize,
         reliability: MediaReliability,
         engine: AudioEngine,
         granularMetrics: Bool) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
        self.engine = engine
        self.granularMetrics = granularMetrics
    }

    func create(_ namespace: QuicrNamespace,
                publishDelegate: QPublishObjectDelegateObjC,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter?) throws -> Publication {

        switch config.codec {
        case .h264:
            guard let config = config as? VideoCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            return try H264Publication(namespace: namespace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       config: config,
                                       metricsSubmitter: metricsSubmitter,
                                       reliable: reliability.video.publication,
                                       granularMetrics: self.granularMetrics)
        case .opus:
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            return try OpusPublication(namespace: namespace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       metricsSubmitter: metricsSubmitter,
                                       opusWindowSize: opusWindowSize,
                                       reliable: reliability.audio.publication,
                                       engine: engine,
                                       granularMetrics: self.granularMetrics)
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}
