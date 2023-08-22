import AVFoundation
import Foundation
import os

class PublisherDelegate: QPublisherDelegateObjC {
    private static let logger = DecimusLogger(PublisherDelegate.self)

    private unowned let captureManager: CaptureManager
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter?
    private let factory: PublicationFactory

    init(publishDelegate: QPublishObjectDelegateObjC,
         metricsSubmitter: MetricsSubmitter?,
         captureManager: CaptureManager,
         opusWindowSize: TimeInterval,
         reliability: MediaReliability) {
        self.captureManager = captureManager
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.factory = .init(capture: captureManager, opusWindowSize: opusWindowSize, reliability: reliability)
    }

    func allocatePub(byNamespace quicrNamepace: QuicrNamespace!,
                     sourceID: SourceIDType!,
                     qualityProfile: String!) -> QPublicationDelegateObjC? {
        let config = CodecFactory.makeCodecConfig(from: qualityProfile!)
        do {
            let publication = try factory.create(quicrNamepace,
                                       publishDelegate: publishDelegate,
                                       sourceID: sourceID,
                                       config: config,
                                       metricsSubmitter: metricsSubmitter)

            guard let h264publication = publication as? FrameListener else {
                return publication
            }

            Task(priority: .medium) { [weak captureManager] in
                try await captureManager?.addInput(h264publication)
            }
            return publication

        } catch {
            Self.logger.error("Failed to allocate publication: \(error.localizedDescription)")
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
