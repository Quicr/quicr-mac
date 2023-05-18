import CoreGraphics
import CoreMedia
import SwiftUI
import AVFAudio
import AVFoundation
import UIKit

/// The core of the application.
protocol ApplicationMode {
    var pipeline: PipelineManager? { get }
    func encodeCameraFrame(identifier: UInt64, frame: CMSampleBuffer)
    func encodeAudioSample(identifier: UInt64, sample: CMSampleBuffer)
    func removeRemoteSource(identifier: UInt64)
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

    var participants: VideoParticipants = VideoParticipants()
    private var checkStaleVideoTimer: Timer?

    private let id = UUID()

    required init(errorWriter: ErrorWriter, player: AudioPlayer, metricsSubmitter: MetricsSubmitter) {
        self.errorHandler = errorWriter
        self.player = player
        self.pipeline = .init(errorWriter: errorWriter, metricsSubmitter: metricsSubmitter)

        self.checkStaleVideoTimer = .scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let staleVideos = self.participants.participants.filter { _, participant in
                return participant.lastUpdated.advanced(by: DispatchTimeInterval.seconds(2)) < .now()
            }
            for id in staleVideos.keys {
                self.removeRemoteSource(identifier: id)
            }
        }

        CodecFactory.shared = .init()
        CodecFactory.shared.registerEncoderCallback { [weak self] id, media in
            guard let mode = self else { return }
            let identified: MediaBufferFromSource = .init(source: id, media: media)
            mode.sendEncodedData(data: identified)
        }
        CodecFactory.shared.registerDecoderCallback { [weak self] id, decoded, _, orientation, mirror in
            guard let mode = self else { return }
            mode.showDecodedImage(identifier: id,
                                  decoded: decoded,
                                  orientation: orientation,
                                  verticalMirror: mirror)
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func showDecodedImage(identifier: UInt64,
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
        participant.lastUpdated = .now()
    }

    func removeRemoteSource(identifier: UInt64) {
        do {
            try participants.removeParticipant(identifier: identifier)
        } catch {
            player.removePlayer(identifier: identifier)
        }
    }

    func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) { }

    func getStreamIdFromDevice(_ identifier: UInt64) -> [UInt64] {
        return [identifier]
    }

    func encodeCameraFrame(identifier: UInt64, frame: CMSampleBuffer) {
        let ids = getStreamIdFromDevice(identifier)
        let sample = frame.asMediaBuffer()
        ids.forEach { pipeline!.encode(identifier: $0, sample: sample) }
    }

    func encodeAudioSample(identifier: UInt64, sample: CMSampleBuffer) {
        let ids = getStreamIdFromDevice(identifier)
        guard let formatDescription = sample.formatDescription else {
            errorHandler.writeError(message: "Missing format description")
            return
        }
        let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        ids.forEach { pipeline!.encode(identifier: $0, sample: sample.getMediaBuffer(userData: audioFormat)) }
    }

    func sendEncodedData(data: MediaBufferFromSource) {}
}
