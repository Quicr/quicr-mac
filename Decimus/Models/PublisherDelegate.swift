import AVFoundation
import Foundation

class PublisherDelegate: QPublisherDelegateObjC {
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter
    private let factory: PublicationFactory
    private let errorWriter: ErrorWriter

    init(publishDelegate: QPublishObjectDelegateObjC,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager,
         errorWriter: ErrorWriter) {
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.factory = .init(capture: captureManager)
        self.errorWriter = errorWriter
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
                                       errorWriter: errorWriter)
        } catch {
            errorWriter.writeError("Failed to allocate publication: \(error.localizedDescription)")
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
