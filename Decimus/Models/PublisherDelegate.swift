import AVFoundation
import Foundation

class PublisherDelegate: QPublisherDelegateObjC {
    private unowned let capture: CaptureManager
    private unowned let publishDelegate: QPublishObjectDelegateObjC
    private let metricsSubmitter: MetricsSubmitter
    private let factory: PublicationFactory
    private let errorWriter: ErrorWriter
    func log(_ message: String) {
        print("[\(String(describing: type(of: self)))] \(message)")
    }

    init(publishDelegate: QPublishObjectDelegateObjC,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager,
         errorWriter: ErrorWriter,
         opusWindowSize: TimeInterval,
         reliability: MediaReliability) {
        self.publishDelegate = publishDelegate
        self.metricsSubmitter = metricsSubmitter
        self.capture = captureManager
        self.factory = .init(opusWindowSize: opusWindowSize, reliability: reliability)
        self.errorWriter = errorWriter
    }
    deinit {
        log("deinit")
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
                                       metricsSubmitter: metricsSubmitter,
                                       errorWriter: errorWriter)

            guard let h264publication = publication as? FrameListener else {
                return publication
            }

            Task(priority: .medium) { [weak capture] in
                try await capture?.addInput(h264publication)
            }
            return publication

        } catch {
            errorWriter.writeError("Failed to allocate publication: \(error.localizedDescription)")
            return nil
        }
    }

    func remove(byNamespace quicrNamepace: String!) -> Int32 {
        return 0
    }
}
