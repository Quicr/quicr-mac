import AVFoundation
import Foundation

struct PublicationSettings: Codable {
    var opusWindowSize: Double
}

class PublisherDelegate: QPublisherDelegateObjC {
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter
    private let factory: PublicationFactory
    private let publicationSettings: PublicationSettings

    init(publishDelegate: QPublishObjectDelegateObjC,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager,
         publicationSettings: PublicationSettings) {
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.factory = .init(capture: captureManager)
        self.publicationSettings = publicationSettings
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!,
                     sourceID: SourceIDType!,
                     qualityProfile: String!) -> QPublicationDelegateObjC? {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        do {
            return try factory.create(quicrNamepace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       config: config,
                                       metricsSubmitter: metricsSubmitter,
                                       publicationSettings: publicationSettings)
        } catch {
            print("[PublisherDelegate] Failed to allocate publication: \(error)")
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
