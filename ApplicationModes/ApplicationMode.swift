import CoreGraphics
import CoreMedia
import SwiftUI
import AVFAudio
import AVFoundation
import UIKit

/// ApplicationMode provides a default implementation of the app.
/// Uncompressed data is passed to the pipeline to encode, encoded data is passed out to be rendered.
/// The intention of exposing this an abstraction layer is to provide an easy way to reconfigure the application
/// to try out new things. For example, a loopback layer.
class ApplicationMode {
    let errorHandler: ErrorWriter
    let player: AudioPlayer

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

    func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {}

    func connect(config: CallConfig) async throws {
        notifier.post(name: .connected, object: self)
    }
    func disconnect() throws {}
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
