import CoreGraphics
import CoreMedia
import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {

    let localMirrorParticipants: UInt32 = 0
    private var h264Encoders: [H264Encoder] = []

    override var root: AnyView {
        get { return .init(InCallView(mode: self) {}) }
        set { }
    }

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[identifier] == nil {
            pipeline!.registerDecoder(identifier: identifier, type: .video)
        }
        pipeline!.decode(mediaBuffer: data.getMediaBuffer(source: identifier))
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[data.source] == nil {
            pipeline!.registerDecoder(identifier: data.source, type: .audio)
        }
        pipeline!.decode(mediaBuffer: data)
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {

        for encoder in h264Encoders {
            encoder.setOrientation(orientation: UIDevice.current.orientation.videoOrientation)
        }

        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            encodeSample(identifier: mirrorIdentifier, frame: frame, type: .video)
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: sample, type: .audio)
    }

    private func encodeSample(identifier: UInt32,
                              frame: CMSampleBuffer,
                              type: PipelineManager.MediaType) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            return
        }

        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }

    override func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
        super.onDeviceChange(device: device, event: event)

        switch event {
        case .removed:
            removeRemoteSource(identifier: device.id)
        default:
            return
        }
    }

    override func createVideoEncoder(identifier: UInt32,
                                     width: Int32,
                                     height: Int32,
                                     orientation: AVCaptureVideoOrientation) {
        let encoder: H264Encoder = .init(width: width, height: height, orientation: orientation) { sample in
            self.sendEncodedImage(identifier: identifier, data: sample)
        }
        h264Encoders.append(encoder)
        pipeline!.registerEncoder(identifier: identifier, encoder: encoder)
    }
}
