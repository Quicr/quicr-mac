import CoreGraphics
import CoreMedia
import SwiftUI
import AVFAudio
import AVFoundation
import UIKit

/// The core of the application.
protocol ApplicationMode {
    var pipeline: PipelineManager? { get }
    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer)
    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer)
    func removeRemoteSource(identifier: UInt32)

    func onCreateEncoder(identifier: UInt32, codec: CodecType)
}

/// ApplicationModeBase provides a default implementation of the app.
/// Uncompressed data is passed to the pipeline to encode, encoded data is passed out to be rendered.
/// The intention of exposing this an abstraction layer is to provide an easy way to reconfigure the application
/// to try out new things. For example, a loopback layer.
class ApplicationModeBase: ApplicationMode, Hashable {
    static func == (lhs: ApplicationModeBase, rhs: ApplicationModeBase) -> Bool {
        false
    }

    var pipeline: PipelineManager?
    let errorHandler: ErrorWriter
    let player: AudioPlayer
    let clientId = UInt16.random(in: 0..<UInt16.max)

    @Published var participants: VideoParticipants = VideoParticipants()

    private let id = UUID()

    required init(errorWriter: ErrorWriter, player: AudioPlayer, metricsSubmitter: MetricsSubmitter) {
        self.errorHandler = errorWriter
        self.player = player
        self.pipeline = .init(errorWriter: errorWriter, metricsSubmitter: metricsSubmitter)

        CodecFactory.shared.registerEncoderSampleCallback { [weak self] id, sample in
            guard let mode = self else { return }
            mode.sendEncodedImage(identifier: id, data: sample)
        }
        CodecFactory.shared.registerEncoderBufferCallback { [weak self] id, media in
            guard let mode = self else { return }
            let identified: MediaBufferFromSource = .init(source: id, media: media)
            mode.sendEncodedAudio(data: identified)
        }
        CodecFactory.shared.registerDecoderSampleCallback { [weak self] id, decoded, _, orientation, mirror in
            guard let mode = self else { return }
            mode.showDecodedImage(identifier: id,
                                  decoded: decoded,
                                  orientation: orientation,
                                  verticalMirror: mirror)
        }
        CodecFactory.shared.registerDecoderBufferCallback { [weak self] id, buffer in
            guard let mode = self else { return }
            mode.player.write(identifier: id, buffer: buffer)
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func showDecodedImage(identifier: UInt32,
                          decoded: CIImage,
                          orientation: AVCaptureVideoOrientation?,
                          verticalMirror: Bool) {
        // Push the image to the output.
        let participant = participants.getOrMake(identifier: identifier)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        let imageOrientation: Image.Orientation
        switch orientation {
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
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: imageOrientation)
    }

    func removeRemoteSource(identifier: UInt32) {
        pipeline!.unregisterDecoders(sourceId: identifier)

        // Remove video renderer.
        do {
            try participants.removeParticipant(identifier: identifier)
        } catch {
            errorHandler.writeError(message: "Failed to remove remote participant (\(identifier)): \(error)")
        }

        player.removePlayer(identifier: identifier)
    }

    func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
        switch event {
        case .added:
            let config: CodecConfig
            if device.hasMediaType(.audio) {
                config = AudioCodecConfig(codec: .opus, bitrate: 0)
            } else if device.hasMediaType(.video) {
                let size = device.activeFormat.formatDescription.dimensions
                config = VideoCodecConfig(codec: .h264,
                                          bitrate: 2048000,
                                          fps: 60,
                                          width: size.width,
                                          height: size.height
                )
            } else {
                fatalError("MediaType not understood for device: \(device.id)")
            }

            pipeline!.registerEncoder(sourceId: device.id, config: config)
            onCreateEncoder(identifier: device.id, codec: config.codec)
        case .removed:
            pipeline!.unregisterEncoders(sourceId: device.id)
        }
    }

    func onCreateEncoder(identifier: UInt32, codec: CodecType) {
    }

    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        pipeline!.encode(identifier: identifier, sample: frame)
    }

    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        pipeline!.encode(identifier: identifier, sample: sample)
    }

    func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {}
    func sendEncodedAudio(data: MediaBufferFromSource) {}
}
