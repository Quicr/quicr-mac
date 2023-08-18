import Foundation

class PublicationFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             QPublishObjectDelegateObjC,
                                             SourceIDType,
                                             CodecConfig,
                                             MetricsSubmitter) throws -> Publication

    private let opusWindowSize: TimeInterval
    private let reliability: MediaReliability

    init(opusWindowSize: TimeInterval, reliability: MediaReliability) {
        self.opusWindowSize = opusWindowSize
        self.reliability = reliability
    }

    // swiftlint:disable function_parameter_count - Dependency injection.
    func create(_ namespace: QuicrNamespace,
                publishDelegate: QPublishObjectDelegateObjC,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter) throws -> Publication {

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
                                                  reliable: reliability.video.publication)
        case .opus:
            guard let config = config as? AudioCodecConfig else {
                throw CodecError.invalidCodecConfig(type(of: config))
            }
            return try OpusPublication(namespace: namespace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       metricsSubmitter: metricsSubmitter,
                                       opusWindowSize: opusWindowSize,
                                       reliable: reliability.audio.publication)
        default:
            throw CodecError.noCodecFound(config.codec)
        }
    }
}
