import AVFoundation
import Foundation

class PublisherDelegate: QPublisherDelegateObjC {
    private let codecFactory: EncoderFactory
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter

    init(publishDelegate: QPublishObjectDelegateObjC, audioFormat: AVAudioFormat, metricsSubmitter: MetricsSubmitter) {
        self.publishDelegate = publishDelegate
        self.codecFactory = .init(audioFormat: audioFormat)
        self.metricsSubmitter = metricsSubmitter
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!) -> QPublicationDelegateObjC! {
        return Publication(namespace: quicrNamepace!,
                           publishDelegate: publishDelegate,
                           codecFactory: codecFactory,
                           metricsSubmitter: metricsSubmitter)
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
