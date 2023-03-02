import CoreGraphics
import CoreMedia
import SwiftUI
import AVFAudio
import AVFoundation

/// The core of the application.
protocol ApplicationMode {
    var pipeline: PipelineManager? { get }
    var root: AnyView { get }
    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer)
    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer)
    func removeRemoteSource(identifier: UInt32)

    func createVideoEncoder(identifier: UInt32, width: Int32, height: Int32)
    func createAudioEncoder(identifier: UInt32)

    func removeEncoder(identifier: UInt32)
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
        let participant = participants.getOrMake(identifier: identifier)
        participant.decodedImage = .init(cgImage: decoded)
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

    func onDeviceChange(device: AVCaptureDevice, event: CaptureManager.DeviceEvent) {
        switch event {
        case .added:
            if device.hasMediaType(.audio) {
                createAudioEncoder(identifier: device.id)
            } else if device.hasMediaType(.video) {
                let size = device.activeFormat.formatDescription.dimensions
                createVideoEncoder(identifier: device.id, width: size.width, height: size.height)
            }
        case .removed:
            removeEncoder(identifier: device.id)
        }
    }

    func createVideoEncoder(identifier: UInt32, width: Int32, height: Int32) {
        pipeline!.registerEncoder(identifier: identifier, width: width, height: height)
    }

    func createAudioEncoder(identifier: UInt32) {
        let encoder: Encoder

        // // Passthrough.
        // encoder = PassthroughEncoder { media in
        //     let identified: MediaBuffer = .init(identifier: identifier, other: media)
        //     self.sendEncodedAudio(data: identified)
        // }

        // // Apple API.
        // let opusFrameSize: UInt32 = 960
        // let opusSampleRate: Float64 = 48000.0
        // var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: opusSampleRate,
        //                                                     mFormatID: kAudioFormatOpus,
        //                                                     mFormatFlags: 0,
        //                                                     mBytesPerPacket: 0,
        //                                                     mFramesPerPacket: opusFrameSize,
        //                                                     mBytesPerFrame: 0,
        //                                                     mChannelsPerFrame: 1,
        //                                                     mBitsPerChannel: 0,
        //                                                     mReserved: 0)
        // let opus: AVAudioFormat = .init(streamDescription: &opusDesc)!
        // encoder = AudioEncoder(to: opus) { sample in
        //     let buffer = sample.getMediaBuffer(identifier: identifier)
        //     self.sendEncodedAudio(data: buffer)
        // }

        // libopus
        encoder = LibOpusEncoder(fileWrite: false) { media in
            let identified: MediaBufferFromSource = .init(source: identifier, media: media)
            self.sendEncodedAudio(data: identified)
        }

        pipeline!.registerEncoder(identifier: identifier, encoder: encoder)
    }

    func removeEncoder(identifier: UInt32) {
        pipeline!.encoders.removeValue(forKey: identifier)
    }

    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {}
    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {}
    func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {}
    func sendEncodedAudio(data: MediaBufferFromSource) {}
}
