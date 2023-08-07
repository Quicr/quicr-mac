import Foundation
import AVFAudio

class PublicationFactory {
    private typealias FactoryCallbackType = (QuicrNamespace,
                                             QPublishObjectDelegateObjC,
                                             SourceIDType,
                                             CodecConfig,
                                             MetricsSubmitter,
                                             ErrorWriter) throws -> Publication

    private unowned let capture: CaptureManager
    private unowned let engine: AVAudioEngine
    init(capture: CaptureManager, engine: AVAudioEngine) {
        self.capture = capture
        self.engine = engine
    }

    private lazy var factories: [CodecType: FactoryCallbackType] = [
        .h264: { [weak self] in
            guard let config = $3 as? VideoCodecConfig else { fatalError() }
            let publication = try H264Publication(namespace: $0,
                                                  publishDelegate: $1,
                                                  sourceID: $2,
                                                  config: config,
                                                  metricsSubmitter: $4,
                                                  errorWriter: $5)

            let capture = self?.capture
            Task(priority: .medium) {
                try await capture?.addInput(publication)
            }

            return publication
        },
        .opus: {
            guard let config = $3 as? AudioCodecConfig else { fatalError() }
            return try OpusPublication(namespace: $0,
                                       publishDelegate: $1,
                                       sourceID: $2,
                                       metricsSubmitter: $4,
                                       errorWriter: $5,
                                       engine: self.engine)
        }
    ]

    // swiftlint:disable function_parameter_count - Dependency injection.
    func create(_ namespace: QuicrNamespace,
                publishDelegate: QPublishObjectDelegateObjC,
                sourceID: SourceIDType,
                config: CodecConfig,
                metricsSubmitter: MetricsSubmitter,
                errorWriter: ErrorWriter) throws -> Publication {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        return try factory(namespace, publishDelegate, sourceID, config, metricsSubmitter, errorWriter)
    }
}
