import Foundation
import CoreGraphics
import CoreMedia
import AVFoundation

/// Manages pipeline elements.
class PipelineManager {

    /// Possible media types that the pipeline understands.
    enum MediaType { case audio; case video }

    /// Represents a decoded image.
    /// - Parameter identifier: The source identifier for this decoded image.
    /// - Parameter image: The decoded image data.
    /// - Parameter timestamp: The timestamp for this image.
    typealias DecodedImageCallback = (_ identifier: UInt32, _ image: CGImage, _ timestamp: CMTimeValue) -> Void

    /// Represents an encoded sample.
    /// - Parameter identifier: The source identifier for this encoded sample.
    /// - Parameter sample: The encoded sample data.
    typealias EncodedSampleCallback = (_ identifier: UInt32, _ sample: CMSampleBuffer) -> Void

    /// Represents a decoded audio sample.
    typealias DecodedAudioCallback = EncodedSampleCallback

    private let imageCallback: DecodedImageCallback
    private let encodedCallback: EncodedSampleCallback
    private let audioCallback: DecodedAudioCallback
    private let encodedAudioCallback: Encoder.EncodedBufferCallback
    private let debugging: Bool

    /// Managed pipeline elements.
    var encoders: [UInt32: EncoderElement] = .init()
    var decoders: [UInt32: DecoderElement] = .init()

    /// Create a new PipelineManager.
    init(
        decodedCallback: @escaping DecodedImageCallback,
        encodedCallback: @escaping EncodedSampleCallback,
        decodedAudioCallback: @escaping DecodedAudioCallback,
        encodedAudioCallback: @escaping Encoder.EncodedBufferCallback,
        debugging: Bool) {
        self.imageCallback = decodedCallback
        self.encodedCallback = encodedCallback
        self.encodedAudioCallback = encodedAudioCallback
        self.audioCallback = decodedAudioCallback
        self.debugging = debugging
    }

    private func debugPrint(message: String) {
        guard debugging else { return }
        print("Pipeline => \(message)")
    }

    func encode(identifier: UInt32, sample: CMSampleBuffer) {
        debugPrint(message: "[\(identifier)] (\(UInt32(sample.presentationTimeStamp.seconds * 1000))) Encode write")
        let encoder: EncoderElement? = encoders[identifier]
        guard encoder != nil else { fatalError("Tried to encode for unregistered identifier: \(identifier)") }
        encoder!.encoder.write(sample: sample)
    }

    func decode(mediaBuffer: MediaBuffer) {
        debugPrint(message: "[\(mediaBuffer.identifier)] (\(mediaBuffer.timestampMs)) Decode write")
        let decoder: DecoderElement? = decoders[mediaBuffer.identifier]
        guard decoder != nil else { return }
        guard decoder != nil else { fatalError("Tried to decode for unregistered identifier: \(mediaBuffer.identifier)") }
        decoder?.decoder.write(data: mediaBuffer.buffer, timestamp: mediaBuffer.timestampMs)
    }

    func registerEncoder(identifier: UInt32, width: Int32, height: Int32) {
        let encoder = H264Encoder(width: width, height: height, callback: { sample in
            self.debugPrint(message: "[\(identifier)] (timestamp) Encoded")
            self.encodedCallback(identifier, sample)
        })
        registerEncoder(identifier: identifier, encoder: encoder)
    }

//    func registerEncoder(identifier: UInt32, encoder: Encoder) {
////        let opusFrameSize: UInt32 = 960
////        let opusSampleRate: Float64 = 48000.0
////        var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: opusSampleRate,
////                                                          mFormatID: kAudioFormatOpus,
////                                                          mFormatFlags: 0,
////                                                          mBytesPerPacket: 0,
////                                                          mFramesPerPacket: opusFrameSize,
////                                                          mBytesPerFrame: 0,
////                                                          mChannelsPerFrame: 1,
////                                                          mBitsPerChannel: 0,
////                                                          mReserved: 0)
////        let opus: AVAudioFormat = .init(streamDescription: &opusDesc)!
//////        let encoder = PassthroughEncoder { sample in
//////            self.encodedAudioCallback(identifier, sample)
//////        }
//////        let encoder = AudioEncoder(to: opus) { sample in
//////            self.encodedAudioCallback(identifier, sample)
//////        }
////        let encoder = LibOpusEncoder( { sample in
////            self.encodedAudioCallback(identifier, sample)
////        }
//        registerEncoder(identifier: identifier, encoder: encoder)
//    }

     func registerEncoder(identifier: UInt32, encoder: Encoder) {
        let element: EncoderElement = .init(identifier: identifier, encoder: encoder)
        encoders[identifier] = element
        debugPrint(message: "[\(identifier)] Registered encoder")
    }

    func registerDecoder(identifier: UInt32, type: MediaType) {
        let decoder: Decoder
        switch type {
        case .video:
//            decoder = H264Decoder(callback: { decodedImage, presentation in
//                self.debugPrint(message: "[\(identifier)] (\(presentation)) Decoded")
//                self.imageCallback(identifier, decodedImage, presentation)
//            })
            return
        case .audio:
            // When it comes from passthrough encoder, we need to look it up.
            // asbd = PassthroughEncoder.format!
            let playoutFormat: AVAudioFormat = .init(commonFormat: .pcmFormatInt16,
                                                     sampleRate: Double(48000),
                                                     channels: 1,
                                                     interleaved: false)!
            decoder = LibOpusDecoder { buffer in
                self.audioCallback(identifier, buffer.toSample(format: playoutFormat.formatDescription))
            }
        }

        let element: DecoderElement = .init(identifier: identifier, decoder: decoder)
        decoders[identifier] = element
        debugPrint(message: "[\(identifier)] Register decoder")
    }
}
