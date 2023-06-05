import CoreMedia
import AVFoundation

class CallController {
    let notifier: NotificationCenter = .default

    let errorHandler: ErrorWriter
    let publisher: Publisher
    let subscriber: Subscriber
    private let controller: QControllerGWObjC = .init()

    required init(errorWriter: ErrorWriter,
                  metricsSubmitter: MetricsSubmitter,
                  inputAudioFormat: AVAudioFormat,
                  outputAudioFormat: AVAudioFormat? = nil) {

        self.errorHandler = errorWriter
        self.publisher = .init(publishDelegate: controller, audioFormat: inputAudioFormat)
        self.subscriber = .init(errorWriter: errorWriter, audioFormat: outputAudioFormat)

        controller.publisherDelegate = self.publisher
        controller.subscriberDelegate = self.subscriber
    }

    func connect(config: CallConfig) async throws {
        controller.connect(config.address, port: config.port, protocol: config.connectionProtocol.rawValue)

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
        controller.updateManifest(manifest)
        notifier.post(name: .connected, object: self)
    }

    func disconnect() throws {
        notifier.post(name: .disconnected, object: self)
    }
}

extension Notification.Name {
    static var connected = Notification.Name("connected")
    static var disconnected = Notification.Name("disconnected")
}
