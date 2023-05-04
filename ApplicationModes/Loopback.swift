import CoreGraphics
import CoreMedia
import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {
    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[identifier] == nil {
            pipeline!.registerDecoder(sourceId: identifier, mediaId: 0, codec: .h264)
        }
        pipeline!.decode(mediaBuffer: data.getMediaBuffer(source: identifier))
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[data.source] == nil {
            pipeline!.registerDecoder(sourceId: data.source, mediaId: 0, codec: .opus)
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
