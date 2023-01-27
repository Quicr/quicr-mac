import CoreGraphics
import CoreMedia
import SwiftUI

/// The core of the application.
protocol ApplicationMode {
    var pipeline: PipelineManager? { get }
    var captureManager: CaptureManager? { get }
    var root: AnyView { get }
}

/// ApplicationModeBase provides a default implementation of the app.
/// Uncompressed data is passed to the pipeline to encode, encoded data is passed out to be rendered.
/// The intention of exposing this an abstraction layer is to provide an easy way to reconfigure the application
/// to try out new things. For example, a loopback layer.
class ApplicationModeBase: ApplicationMode {
    
    var pipeline: PipelineManager?
    var captureManager: CaptureManager?
    var root: AnyView = .init(EmptyView())
    
    init(participants: VideoParticipants, player: AudioPlayer) {
        pipeline = .init(
            decodedCallback: { identifier, decoded, _ in
                self.showDecodedImage(identifier: identifier, participants: participants, decoded: decoded)
            },
            encodedCallback: { identifier, data in
                self.sendEncodedImage(identifier: identifier, data: data)
            },
            decodedAudioCallback: { _, sample in
                self.playDecodedAudio(sample: sample, player: player)
            },
            encodedAudioCallback: { identifier, data in
                self.sendEncodedAudio(identifier: identifier, data: data)
            },
            debugging: false)
        captureManager = .init(
            cameraCallback: { frame in
                self.encodeCameraFrame(frame: frame)
            },
            audioCallback: { sample in
                self.encodeAudioSample(sample: sample)
            })
    }
    
    func showDecodedImage(identifier: UInt32, participants: VideoParticipants, decoded: CGImage) {
        // Push the image to the output.
        DispatchQueue.main.async {
            let participant = participants.getOrMake(identifier: identifier)
            participant.decodedImage = .init(cgImage: decoded)
        }
    }
    
    func playDecodedAudio(sample: CMSampleBuffer, player: AudioPlayer) {
        player.write(sample: sample)
    }
    
    func encodeCameraFrame(frame: CMSampleBuffer) {}
    func encodeAudioSample(sample: CMSampleBuffer) {}
    func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {}
    func sendEncodedAudio(identifier: UInt32, data: CMSampleBuffer) {}
}
