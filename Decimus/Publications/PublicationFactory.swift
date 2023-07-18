import Foundation

class PublicationFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             QPublishObjectDelegateObjC,
                                             SourceIDType,
                                             CodecConfig,
                                             MetricsSubmitter,
                                             PublicationSettings) -> Publication

    private unowned let capture: CaptureManager
    init(capture: CaptureManager) {
        self.capture = capture
    }

    private lazy var factories: [CodecType: FactoryCallbackType] = [
        .h264: { [weak self] in
            guard let config = $3 as? VideoCodecConfig else { fatalError() }
            _ = $5
            let publication = H264Publication(namespace: $0,
                                              publishDelegate: $1,
                                              sourceID: $2,
                                              config: config,
                                              metricsSubmitter: $4)

            let capture = self?.capture
            Task(priority: .medium) {
                await capture?.addInput(publication)
            }

            return publication
        },
        .opus: {
            guard let config = $3 as? AudioCodecConfig else { fatalError() }
            return OpusPublication(namespace: $0,
                                   publishDelegate: $1,
                                   sourceID: $2,
                                   metricsSubmitter: $4,
                                   opusWindowSize: $5.opusWindowSize)
        }
    ]

    func create(_ namespace: QuicrNamespace,
                publishDelegate: QPublishObjectDelegateObjC,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter,
                publicationSettings: PublicationSettings) throws -> Publication {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        return factory(namespace, publishDelegate, sourceID, config, metricsSubmitter, publicationSettings)
    }
}
