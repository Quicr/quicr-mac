import SwiftUI
import CoreMedia
import AVFoundation

enum ApplicationError: Error {
    case emptyEncoder
    case alreadyConnected
    case notConnected
}

class CallController {
    let errorHandler: ErrorWriter

    let publisher: Publisher = .init()
    let subscriber: Subscriber?

    let player: AudioPlayer

    let controller: QControllerGWObjC = .init()

    var participants: VideoParticipants = VideoParticipants()
    private var checkStaleVideoTimer: Timer?

    var notifier: NotificationCenter = .default

    private let id = UUID()

    required init(errorWriter: ErrorWriter,
                  player: AudioPlayer,
                  metricsSubmitter: MetricsSubmitter,
                  inputAudioFormat: AVAudioFormat,
                  outputAudioFormat: AVAudioFormat) {

        self.errorHandler = errorWriter
        self.player = player

        self.subscriber = .init(errorWriter: errorWriter)

        controller.publisherDelegate = self.publisher
        controller.subscriberDelegate = self.subscriber

        self.checkStaleVideoTimer = .scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            let staleVideos = self.participants.participants.filter { _, participant in
                return participant.lastUpdated.advanced(by: DispatchTimeInterval.seconds(2)) < .now()
            }
            for id in staleVideos.keys {
                self.removeRemoteSource(identifier: id)
            }
        }

        CodecFactory.shared = .init(inputAudioFormat: inputAudioFormat, outputAudioFormat: outputAudioFormat)
        CodecFactory.shared.registerDecoderCallback { [weak self] id, decoded, _, orientation, mirror in
            guard let mode = self else { return }
            mode.showDecodedImage(identifier: id, decoded: decoded, orientation: orientation, verticalMirror: mirror)
        }
        CodecFactory.shared.registerDecoderCallback { [weak self] id, buffer in
            guard let mode = self else { return }
            mode.player.write(identifier: id, buffer: buffer)
        }
    }

    deinit {
        checkStaleVideoTimer!.invalidate()
        CodecFactory.shared = nil
    }

    func showDecodedImage(identifier: StreamIDType,
                          decoded: CIImage,
                          orientation: AVCaptureVideoOrientation?,
                          verticalMirror: Bool) {
        let participant = participants.getOrMake(identifier: identifier)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        let imageOrientation = orientation?.toImageOrientation(verticalMirror) ?? .up
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: imageOrientation)
        participant.lastUpdated = .now()
    }

    func removeRemoteSource(identifier: StreamIDType) {
        do {
            try participants.removeParticipant(identifier: identifier)
        } catch {
            player.removePlayer(identifier: identifier)
        }
    }

    func connect(config: CallConfig) async throws {
        controller.connect(config.address, port: config.port, protocol: config.connectionProtocol.rawValue)

        let manifest = await ManifestController.shared.getManifest(confId: config.conferenceId, email: config.email)
        controller.updateManifest(manifest)
        notifier.post(name: .connected, object: self)
    }

    func disconnect() throws {
    }

    func encodeCameraFrame(identifier: SourceIDType, frame: CMSampleBuffer) {
    }

    func encodeAudioSample(identifier: SourceIDType, sample: CMSampleBuffer) {
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

extension AVCaptureVideoOrientation {
    func toImageOrientation(_ verticalMirror: Bool) -> Image.Orientation {
        let imageOrientation: Image.Orientation
        switch self {
        case .portrait:
            imageOrientation = verticalMirror ? .leftMirrored : .right
        case .landscapeLeft:
            imageOrientation = verticalMirror ? .upMirrored : .down
        case .landscapeRight:
            imageOrientation = verticalMirror ? .downMirrored : .up
        case .portraitUpsideDown:
            imageOrientation = verticalMirror ? .rightMirrored : .left
        default:
            imageOrientation = .up
        }
        return imageOrientation
    }
}

extension Notification.Name {
    static var connected = Notification.Name("connected")
}
