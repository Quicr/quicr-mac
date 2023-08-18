import CoreMedia
import AVFoundation
import os

enum CallError: Error {
    case failedToConnect(Int32)
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: CallController.self)
    )

    init(errorWriter: ErrorWriter,
         metricsSubmitter: MetricsSubmitter,
         captureManager: CaptureManager,
         config: SubscriptionConfig) {
        super.init()
        self.subscriberDelegate = SubscriberDelegate(errorWriter: errorWriter,
                                                     submitter: metricsSubmitter,
                                                     config: config)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   metricsSubmitter: metricsSubmitter,
                                                   captureManager: captureManager,
                                                   errorWriter: errorWriter,
                                                   opusWindowSize: config.opusWindowSize,
                                                   reliability: config.mediaReliability)
    }
    deinit {
        Self.logger.trace("deinit")
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
