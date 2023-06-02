import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
    case notConnected
}

class CallController {
    let id = UUID()
    let notifier: NotificationCenter = .default

    let errorHandler: ErrorWriter
    let publisher: Publisher
    let subscriber: Subscriber
    let controller: QControllerGWObjC = .init()

    required init(errorWriter: ErrorWriter,
                  metricsSubmitter: MetricsSubmitter,
                  inputAudioFormat: AVAudioFormat,
                  outputAudioFormat: AVAudioFormat? = nil) {

        self.errorHandler = errorWriter
        self.publisher = .init(audioFormat: inputAudioFormat)
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

extension Sequence {
    func concurrentForEach(_ operation: @escaping (Element) async -> Void) async {
        // A task group automatically waits for all of its
        // sub-tasks to complete, while also performing those
        // tasks in parallel:
        await withTaskGroup(of: Void.self) { group in
            for element in self {
                group.addTask {
                    await operation(element)
                }
            }
        }
    }
}

extension Notification.Name {
    static var connected = Notification.Name("connected")
    static var disconnected = Notification.Name("disconnected")
}
