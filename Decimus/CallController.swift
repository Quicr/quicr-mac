import CoreMedia
import AVFoundation

enum CallError: Error {
    case failedToConnect(Int32)
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    let notifier: NotificationCenter = .default

    init(errorWriter: ErrorWriter,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager,
         engine: AVAudioEngine) {
        super.init()
        self.subscriberDelegate = SubscriberDelegate(errorWriter: errorWriter,
                                                     submitter: metricsSubmitter,
                                                     engine: engine)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   errorWriter: errorWriter,
                                                   engine: engine)
    }

    func connect(config: CallConfig) async throws {
        let error = super.connect(config.address, port: config.port, protocol: config.connectionProtocol.rawValue)
        guard error == .zero else {
            throw CallError.failedToConnect(error)
        }

        let manifest = try await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)
        super.updateManifest(manifest)
    }

    func disconnect() throws {
        super.close()
    }
}
