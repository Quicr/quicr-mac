import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {

    var pipeline: PipelineManager?

    required init(errorWriter: ErrorWriter, player: AudioPlayer, metricsSubmitter: MetricsSubmitter) {
        super.init(errorWriter: errorWriter, player: player, metricsSubmitter: metricsSubmitter)
        self.pipeline = .init(errorWriter: errorWriter, metricsSubmitter: metricsSubmitter)
    }

    override func encodeCameraFrame(identifier: UInt64, frame: CMSampleBuffer) {
        let sample = frame.asMediaBuffer()
        pipeline!.encode(identifier: identifier, buffer: sample)
    }

    override func encodeAudioSample(identifier: UInt64, sample: CMSampleBuffer) {
        guard let formatDescription = sample.formatDescription else {
            errorHandler.writeError(message: "Missing format description")
            return
        }
        let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        pipeline!.encode(identifier: identifier, buffer: sample.getMediaBuffer(userData: audioFormat))
    }

    override func sendEncodedData(identifier: UInt64, data: MediaBuffer) {
        // Loopback: Write encoded data to decoder.
        pipeline!.decode(identifier: identifier, buffer: data)
    }

    override func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
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

            pipeline!.registerEncoder(identifier: device.id, config: config)
            if let decoder = pipeline!.registerDecoder(identifier: device.id, config: config) as? BufferDecoder {
                player.addPlayer(identifier: device.id, format: decoder.decodedFormat)
            }
        case .removed:
            pipeline!.unregisterEncoder(identifier: device.id)
            pipeline!.unregisterDecoder(identifier: device.id)
            removeRemoteSource(identifier: device.id)
        }
    }
}
