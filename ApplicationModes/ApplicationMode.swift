import CoreGraphics
import CoreMedia
import SwiftUI
import AVFAudio
import AVFoundation
import UIKit

/// The core of the application.
protocol ApplicationMode {
    var pipeline: PipelineManager? { get }
    var root: AnyView { get }
    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer)
    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer)
    func removeRemoteSource(identifier: UInt32)

    func createVideoEncoder(identifier: UInt32,
                            width: Int32,
                            height: Int32,
                            orientation: AVCaptureVideoOrientation?,
                            verticalMirror: Bool)
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
    let errorHandler: ErrorWriter
    private var h264Encoders: [H264Encoder] = []

    init(participants: VideoParticipants, player: AudioPlayer, errorWriter: ErrorWriter) {
        self.participants = participants
        self.player = player
        self.errorHandler = errorWriter
        pipeline = .init(
            decodedCallback: { identifier, decoded, _, orientation, verticalMirror in
                self.showDecodedImage(identifier: identifier,
                                      participants: participants,
                                      decoded: decoded,
                                      orientation: orientation,
                                      verticalMirror: verticalMirror)
            },
            encodedCallback: { identifier, data in
                self.sendEncodedImage(identifier: identifier, data: data)
            },
            decodedAudioCallback: { identifier, sample in
                self.playDecodedAudio(identifier: identifier, buffer: sample, player: player)
            },
            encodedAudioCallback: self.sendEncodedAudio,
            debugging: false,
            errorWriter: errorWriter)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func showDecodedImage(identifier: UInt32,
                          participants: VideoParticipants,
                          decoded: CIImage,
                          orientation: AVCaptureVideoOrientation?,
                          verticalMirror: Bool) {
        // Push the image to the output.
        let participant = participants.getOrMake(identifier: identifier)

        // TODO: Why can't we use CIImage directly here?
        let image: CGImage = CIContext().createCGImage(decoded, from: decoded.extent)!
        let imageOrientation: Image.Orientation
        switch orientation {
        case .portrait:
            imageOrientation = verticalMirror ? .leftMirrored : .right
        case .landscapeLeft:
            imageOrientation = verticalMirror ? .upMirrored : .down
        case .landscapeRight:
            imageOrientation = verticalMirror ? .downMirrored : .up
        case .portraitUpsideDown:
            imageOrientation = verticalMirror ? .rightMirrored : .left
        default:
            imageOrientation = .up
        }
        participant.decodedImage = .init(decorative: image, scale: 1.0, orientation: imageOrientation)
    }

    func playDecodedAudio(identifier: UInt32, buffer: AVAudioPCMBuffer, player: AudioPlayer) {
        player.write(identifier: identifier, buffer: buffer)
    }

    func removeRemoteSource(identifier: UInt32) {
        // Remove decoder for this source.
        _ = pipeline!.decoders.removeValue(forKey: identifier)

        // Remove video renderer.
        if participants.participants[identifier] != nil {
            do {
                try participants.removeParticipant(identifier: identifier)
            } catch {
                errorHandler.writeError(message: "Failed to remove remote participant: \(error)")
            }
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
                var orientation: AVCaptureVideoOrientation?
                #if !targetEnvironment(macCatalyst)
                    orientation = UIDevice.current.orientation.videoOrientation
                #endif
                createVideoEncoder(identifier: device.id,
                                   width: size.width,
                                   height: size.height,
                                   orientation: orientation,
                                   verticalMirror: device.position == .front)
            }
        case .removed:
            removeEncoder(identifier: device.id)
        }
    }

    func createVideoEncoder(identifier: UInt32,
                            width: Int32,
                            height: Int32,
                            orientation: AVCaptureVideoOrientation?,
                            verticalMirror: Bool) {
        let encoder: H264Encoder = .init(width: width,
                                         height: height,
                                         orientation: orientation,
                                         verticalMirror: verticalMirror) { sample in
            self.sendEncodedImage(identifier: identifier, data: sample)
        }
        h264Encoders.append(encoder)
        pipeline!.registerEncoder(identifier: identifier, encoder: encoder)
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
        encoder = LibOpusEncoder { media in
            let identified: MediaBufferFromSource = .init(source: identifier, media: media)
            self.sendEncodedAudio(data: identified)
        }

        pipeline!.registerEncoder(identifier: identifier, encoder: encoder)
    }

    func removeEncoder(identifier: UInt32) {
        pipeline!.encoders.removeValue(forKey: identifier)
    }

    func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        #if !targetEnvironment(macCatalyst)
            for encoder in h264Encoders {
                encoder.setOrientation(orientation: UIDevice.current.orientation.videoOrientation)
            }
        #endif

        pipeline!.encode(identifier: identifier, sample: frame)
    }

    func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        pipeline!.encode(identifier: identifier, sample: sample)
    }

    func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {}
    func sendEncodedAudio(data: MediaBufferFromSource) {}
}
