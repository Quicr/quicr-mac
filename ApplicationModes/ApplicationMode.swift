import CoreGraphics
import CoreMedia
import SwiftUI
import AVFAudio

/// The core of the application.
protocol ApplicationMode {
    var pipeline: PipelineManager? { get }
    var root: AnyView { get }
    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer)
    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer)
    func removeRemoteSource(identifier: UInt32)
}

/// ApplicationModeBase provides a default implementation of the app.
/// Uncompressed data is passed to the pipeline to encode, encoded data is passed out to be rendered.
/// The intention of exposing this an abstraction layer is to provide an easy way to reconfigure the application
/// to try out new things. For example, a loopback layer.
class ApplicationModeBase: ApplicationMode, Hashable {

    static func == (lhs: ApplicationModeBase, rhs: ApplicationModeBase) -> Bool {
        false
    }

    var pipeline: PipelineManager?
    var root: AnyView = .init(EmptyView())
    private let id = UUID()
    let clientId = UInt16.random(in: 0..<UInt16.max)
    let participants: VideoParticipants
    let player: AudioPlayer

    init(participants: VideoParticipants, player: AudioPlayer) {
        self.participants = participants
        self.player = player
        pipeline = .init(
            decodedCallback: { identifier, decoded, _ in
                self.showDecodedImage(identifier: identifier, participants: participants, decoded: decoded)
            },
            encodedCallback: { identifier, data in
                self.sendEncodedImage(identifier: identifier, data: data)
            },
            decodedAudioCallback: { identifier, sample in
                self.playDecodedAudio(identifier: identifier, buffer: sample, player: player)
            },
            encodedAudioCallback: self.sendEncodedAudio,
            debugging: false)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func showDecodedImage(identifier: UInt32, participants: VideoParticipants, decoded: CGImage) {
        // Push the image to the output.
        DispatchQueue.main.async {
            let participant = participants.getOrMake(identifier: identifier)
            participant.decodedImage = .init(cgImage: decoded)
        }
    }

    func playDecodedAudio(identifier: UInt32, buffer: AVAudioPCMBuffer, player: AudioPlayer) {
        player.write(identifier: identifier, buffer: buffer)
    }

    func removeRemoteSource(identifier: UInt32) {
        // Remove decoder for this source.
        _ = pipeline!.decoders.removeValue(forKey: identifier)

        // Remove video renderer.
        if participants.participants[identifier] != nil {
            participants.removeParticipant(identifier: identifier)
        }

        // TODO: Remove audio player here.
    }

    func onDeviceChange(identifier: UInt32, event: CaptureManager.DeviceEvent) {}
    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {}
    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {}
    func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {}
    func sendEncodedAudio(data: MediaBufferFromSource) {}
}
