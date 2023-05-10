import CoreGraphics
import CoreMedia
import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {
    override func sendEncodedImage(identifier: UInt64, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[identifier] == nil {
            pipeline!.registerDecoder(identifier: identifier, config: AudioCodecConfig(codec: .h264, bitrate: 0))
        }
        pipeline!.decode(mediaBuffer: data.getMediaBuffer(source: identifier))
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[data.source] == nil {
            pipeline!.registerDecoder(identifier: data.source, config: AudioCodecConfig(codec: .opus, bitrate: 0))
        }
        pipeline!.decode(mediaBuffer: data)
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
}
