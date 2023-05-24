import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {

    override func sendEncodedData(data: MediaBufferFromSource) {
        // Loopback: Write encoded data to decoder.
        pipeline!.decode(mediaBuffer: data)
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
