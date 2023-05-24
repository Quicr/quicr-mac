import CoreMedia
import SwiftUI
import AVFoundation

class RawLoopback: ApplicationModeBase {

    let localMirrorParticipants: UInt64 = 0
    private var devices: [UInt64: AVCaptureDevice.Position] = [:]

    override func sendEncodedData(identifier: UInt64, data: MediaBuffer) {
        // NOOP.
    }

    override func encodeCameraFrame(identifier: UInt64, frame: CMSampleBuffer) {
        let mirror = devices[identifier] == .front
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            let ciImage: CIImage = .init(cvImageBuffer: frame.imageBuffer!)
            var orientation: AVCaptureVideoOrientation?
            #if !targetEnvironment(macCatalyst)
                orientation = UIDevice.current.orientation.videoOrientation
            #endif
            showDecodedImage(identifier: mirrorIdentifier,
                             decoded: ciImage,
                             orientation: orientation,
                             verticalMirror: mirror)
        }
    }

    override func encodeAudioSample(identifier: UInt64, sample: CMSampleBuffer) {
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
