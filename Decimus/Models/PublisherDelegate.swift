import AVFoundation
import Foundation

class PublisherDelegate: QPublisherDelegateObjC {
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter
    private let factory: PublicationFactory

    init(publishDelegate: QPublishObjectDelegateObjC,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager) {
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.factory = .init(capture: captureManager)
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!, sourceID: SourceIDType!, qualityProfile: String!) -> QPublicationDelegateObjC? {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        return try? factory.create(quicrNamepace,
                                   publishDelegate: publishDelegate,
                                   sourceID: sourceID,
                                   config: config,
                                   metricsSubmitter: metricsSubmitter)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
