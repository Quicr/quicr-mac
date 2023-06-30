import AVFoundation
import Foundation

class PublisherDelegate: QPublisherDelegateObjC {
    private let codecFactory: EncoderFactory
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter
    private let captureManager: CaptureManager

    init(publishDelegate: QPublishObjectDelegateObjC,
         audioFormat: AVAudioFormat,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager) {
        self.publishDelegate = publishDelegate
        self.codecFactory = .init(audioFormat: audioFormat)
        self.metricsSubmitter = metricsSubmitter
        self.captureManager = captureManager
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!, qualityProfile: String!) -> QPublicationDelegateObjC! {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        switch config.codec {
        case .opus:
            return OpusPublication(namespace: quicrNamepace,
                                   publishDelegate: publishDelegate,
                                   codecFactory: codecFactory,
                                   metricsSubmitter: metricsSubmitter)
        default:
            return Publication(namespace: quicrNamepace!,
                               publishDelegate: publishDelegate,
                               codecFactory: codecFactory,
                               metricsSubmitter: metricsSubmitter,
                               captureManager: captureManager)
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
