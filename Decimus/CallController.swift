import CoreMedia
import AVFoundation

enum CallError: Error {
    case failedToConnect(Int32)
}

class CallController: QControllerGWObjC<PublisherDelegate, SubscriberDelegate> {
    let notifier: NotificationCenter = .default

    init(errorWriter: ErrorWriter,
         metricsSubmitter: MetricsSubmitter,
         inputAudioFormat: AVAudioFormat,
         outputAudioFormat: AVAudioFormat? = nil) {
        super.init()
        self.subscriberDelegate = SubscriberDelegate(errorWriter: errorWriter,
                                                     audioFormat: outputAudioFormat,
                                                     submitter: metricsSubmitter)
        self.publisherDelegate = PublisherDelegate(publishDelegate: self,
                                                   audioFormat: inputAudioFormat,
                                                   metricsSubmitter: metricsSubmitter,
                                                   errorWriter: errorWriter)
    }

    func connect(config: CallConfig) async throws {
        let error = super.connect(config.address, port: config.port, protocol: config.connectionProtocol.rawValue)
        guard error == .zero else {
            throw CallError.failedToConnect(error)
        }

        let manifest = try await ManifestController.shared.getManifest(confId: config.conferenceID, email: config.email)
        super.updateManifest(manifest)
        notifier.post(name: .connected, object: self)
    }

    func disconnect() throws {
        super.close()
        notifier.post(name: .disconnected, object: self)
    }
}

extension Notification.Name {
    static let connected = Notification.Name("connected")
    static let disconnected = Notification.Name("disconnected")
}
