import CoreMedia
import SwiftUI
import AVFoundation

class RawLoopback: ApplicationModeBase {

    let localMirrorParticipants: UInt32 = 0

    override var root: AnyView {
        get { return .init(InCallView(mode: self) {}) }
        set { }
    }

    override func createVideoEncoder(identifier: UInt32, width: Int32, height: Int32, orientation: AVCaptureVideoOrientation) {}
    override func createAudioEncoder(identifier: UInt32) {}

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // NOOP.
    }

    override func sendEncodedAudio(data: MediaBufferFromSource) {
        // NOOP.
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            let ciImage: CIImage = .init(cvImageBuffer: frame.imageBuffer!)
            showDecodedImage(identifier: mirrorIdentifier,
                             participants: participants,
                             decoded: ciImage,
                             orientation: UIDevice.current.orientation.videoOrientation)
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        playDecodedAudio(identifier: identifier, buffer: .fromSample(sample: sample), player: player)
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
