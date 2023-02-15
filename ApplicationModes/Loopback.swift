import CoreGraphics
import CoreMedia
import SwiftUI
import AVFoundation

class Loopback: ApplicationModeBase {

    let localMirrorParticipants: UInt32 = 0

    override var root: AnyView {
        get { return .init(InCallView(mode: self) {}) }
        set { }
    }

    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[identifier] == nil {
            pipeline!.registerDecoder(identifier: identifier, type: .video)
        }
        pipeline!.decode(mediaBuffer: data.getMediaBuffer(identifier: identifier))
    }

    override func sendEncodedAudio(data: MediaBuffer) {
        // Loopback: Write encoded data to decoder.
        if pipeline!.decoders[data.identifier] == nil {
            pipeline!.registerDecoder(identifier: data.identifier, type: .audio)
        }
        pipeline!.decode(mediaBuffer: data)
    }

    override func encodeCameraFrame(identifier: UInt32, frame: CMSampleBuffer) {
        for offset in 0...localMirrorParticipants {
            let mirrorIdentifier = identifier + offset
            encodeSample(identifier: mirrorIdentifier, frame: frame, type: .video) {
                let size = frame.formatDescription!.dimensions
                pipeline!.registerEncoder(identifier: mirrorIdentifier, width: size.width, height: size.height)
            }
        }
    }

    override func encodeAudioSample(identifier: UInt32, sample: CMSampleBuffer) {
        encodeSample(identifier: identifier, frame: sample, type: .audio) {
            let encoder: Encoder

            // Passthrough.
//            encoder = PassthroughEncoder { media in
//                let identified: MediaBuffer = .init(identifier: identifier, other: media)
//                self.sendEncodedAudio(data: identified)
//            }

            // Apple API.
//            let opusFrameSize: UInt32 = 960
//            let opusSampleRate: Float64 = 48000.0
//            var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: opusSampleRate,
//                                                              mFormatID: kAudioFormatOpus,
//                                                              mFormatFlags: 0,
//                                                              mBytesPerPacket: 0,
//                                                              mFramesPerPacket: opusFrameSize,
//                                                              mBytesPerFrame: 0,
//                                                              mChannelsPerFrame: 1,
//                                                              mBitsPerChannel: 0,
//                                                              mReserved: 0)
//            let opus: AVAudioFormat = .init(streamDescription: &opusDesc)!
//            encoder = AudioEncoder(to: opus) { sample in
//                let buffer = sample.getMediaBuffer(identifier: identifier)
//                self.sendEncodedAudio(data: buffer)
//            }

            // libopus
            encoder = LibOpusEncoder(fileWrite: false) { media in
                let identified: MediaBuffer = .init(identifier: identifier, other: media)
                self.sendEncodedAudio(data: identified)
            }

            pipeline!.registerEncoder(identifier: identifier, encoder: encoder)
        }
    }

    private func encodeSample(identifier: UInt32,
                              frame: CMSampleBuffer,
                              type: PipelineManager.MediaType,
                              register: () -> Void) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            register()
        }

        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }
}
