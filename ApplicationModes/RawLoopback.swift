import CoreMedia
import SwiftUI
import AVFoundation

class RawLoopback: ApplicationModeBase {

    let localMirrorParticipants: UInt32 = 0
    private var devices: [UInt32: AVCaptureDevice.Position] = [:]

    override func createVideoEncoder(identifier: UInt32,
                                     width: Int32,
                                     height: Int32,
                                     orientation: AVCaptureVideoOrientation?,
                                     verticalMirror: Bool) {}
    override func createAudioEncoder(identifier: UInt32) {}

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // NOOP.
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        // NOOP.
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        let mirror = devices[identifier] == .front
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            let ciImage: CIImage = .init(cvImageBuffer: frame.imageBuffer!)
            var orientation: AVCaptureVideoOrientation?
            #if !targetEnvironment(macCatalyst)
                orientation = UIDevice.current.orientation.videoOrientation
            #endif
            showDecodedImage(identifier: mirrorIdentifier,
                             participants: participants,
                             decoded: ciImage,
                             orientation: orientation,
                             verticalMirror: mirror)
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        player.write(identifier: identifier, buffer: .fromSample(sample: sample))
    }

    override func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
        switch event {
        case .added:
            devices[device.id] = device.position
        case .removed:
            removeRemoteSource(identifier: device.id)
        }
    }
}
