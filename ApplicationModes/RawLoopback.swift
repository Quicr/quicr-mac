import CoreMedia
import SwiftUI
import AVFAudio

class RawLoopback: ApplicationModeBase {

    let localMirrorParticipants: UInt32 = 0

    override var root: AnyView {
        get { return .init(InCallView(mode: self) {}) }
        set { }
    }

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // NOOP.
    }

    override func sendEncodedAudio(data: MediaBuffer) {
        // NOOP.
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            let ciImage: CIImage = .init(cvImageBuffer: frame.imageBuffer!)
            let cgImage = CIContext().createCGImage(ciImage, from: ciImage.extent)!
            showDecodedImage(identifier: mirrorIdentifier,
                             participants: participants,
                             decoded: cgImage)
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        playDecodedAudio(buffer: sample, player: player)
    }
}
