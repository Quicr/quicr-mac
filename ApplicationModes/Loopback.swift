import CoreGraphics
import CoreMedia
import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {
    let localMirrorParticipants: UInt32 = 0

    deinit {
        print("Destroyed Loopback")
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
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            super.encodeCameraFrame(identifier: mirrorIdentifier, frame: frame)
        }
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
                                     orientation: AVCaptureVideoOrientation?,
                                     verticalMirror: Bool) {
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            super.createVideoEncoder(identifier: mirrorIdentifier,
                                     width: width,
                                     height: height,
                                     orientation: orientation,
                                     verticalMirror: verticalMirror)
        }
    }
}
