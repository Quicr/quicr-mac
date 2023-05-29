import SwiftUI
import AVFoundation

class Loopback: ApplicationMode {

    var pipeline: PipelineManager?

    required init(errorWriter: ErrorWriter,
                  player: AudioPlayer,
                  metricsSubmitter: MetricsSubmitter,
                  inputAudioFormat: AVAudioFormat,
                  outputAudioFormat: AVAudioFormat) {
        super.init(errorWriter: errorWriter,
                   player: player,
                   metricsSubmitter: metricsSubmitter,
                   inputAudioFormat: inputAudioFormat,
                   outputAudioFormat: outputAudioFormat)
        self.pipeline = .init(errorWriter: errorWriter, metricsSubmitter: metricsSubmitter)
    }

    override func connect(config: CallConfig) async throws {
        if let device = AVCaptureDevice.default(for: .audio) {
            let config = AudioCodecConfig(codec: .opus, bitrate: 0)

            pipeline!.registerEncoder(identifier: device.id, config: config) { [weak self] media in
                guard let mode = self else { return }
                mode.pipeline!.decode(identifier: device.id, buffer: media)
            }
            if let decoder = pipeline!.registerDecoder(identifier: device.id, config: config) as? BufferDecoder {
                player.addPlayer(identifier: device.id, format: decoder.decodedFormat)
            }
            notifier.post(name: .publicationPreparedForDevice, object: device)
        }

        if let device = AVCaptureDevice.default(for: .video) {
            let size = device.activeFormat.formatDescription.dimensions
            let config = VideoCodecConfig(codec: .h264,
                                      bitrate: 2048000,
                                      fps: 60,
                                      width: size.width,
                                      height: size.height
            )

            pipeline!.registerEncoder(identifier: device.id, config: config) { [weak self] media in
                guard let mode = self else { return }
                mode.pipeline!.decode(identifier: device.id, buffer: media)
            }
            pipeline!.registerDecoder(identifier: device.id, config: config)
            notifier.post(name: .publicationPreparedForDevice, object: device)
        }
    }

    override func encodeCameraFrame(identifier: SourceIDType, frame: CMSampleBuffer) {
        let sample = frame.asMediaBuffer()
        pipeline!.encode(identifier: AVCaptureDevice(uniqueID: identifier)!.id, buffer: sample)
    }

    override func encodeAudioSample(identifier: SourceIDType, sample: CMSampleBuffer) {
        guard let formatDescription = sample.formatDescription else {
            errorHandler.writeError(message: "Missing format description")
            return
        }
        let audioFormat: AVAudioFormat = .init(cmAudioFormatDescription: formatDescription)
        pipeline!.encode(identifier: AVCaptureDevice(uniqueID: identifier)!.id, buffer: sample.getMediaBuffer(userData: audioFormat))
    }

    override func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
        switch event {
        case .added:
            print()
        case .removed:
            pipeline!.unregisterEncoder(identifier: device.id)
            pipeline!.unregisterDecoder(identifier: device.id)
            removeRemoteSource(identifier: device.id)
        }
    }
}
