import AVFoundation
import CoreImage
import Foundation

/// Codec type mappings.
enum CodecType: UInt8 {
    case h264 = 0b1010_0000
    case opus = 0b0001_0000
}

/// Possible media types that the pipeline understands.
enum MediaType { case audio; case video }

protocol CodecConfig {
    var codec: CodecType {get}
    var bitrate: UInt32 {get}
}

struct VideoCodecConfig: CodecConfig {
    let codec: CodecType
    let bitrate: UInt32
    let fps: UInt16
    let width: Int32
    let height: Int32
}

struct AudioCodecConfig: CodecConfig {
    let codec: CodecType
    let bitrate: UInt32
}

class CodecFactory {
    static let shared = CodecFactory()

    private var encoderFactories: [CodecType: (CodecConfig) -> Encoder] = [
        .h264: { config in
            guard let config = config as? VideoCodecConfig else { fatalError() }
            return H264Encoder(config: config, verticalMirror: false)
        },
        .opus: { _ in return LibOpusEncoder() }
    ]

    private var decoderFactories: [CodecType: () -> Decoder] = [
        .h264: H264Decoder.init,
        .opus: {
            let opusFormat = AVAudioFormat(opusPCMFormat: .float32,
                                           sampleRate: .opus48khz,
                                           channels: 1)!
            return LibOpusDecoder(format: opusFormat)
        }
    ]

    /// Represents an encoded image.
    /// - Parameter identifier: The source identifier for this encoded image.
    /// - Parameter sample: The sample being encoded
    typealias EncodedImageCallback = (_ identifier: UInt32,
                                      _ sample: CMSampleBuffer) -> Void


    /// Represents an encoded audio sample.
    /// - Parameter identifier: The source identifier for this encoded image.
    /// - Parameter buffer: The buffer being encoded
    typealias EncodedAudioCallback = (_ identifier: UInt32,
                                      _ buffer: MediaBuffer) -> Void

    /// Represents a decoded image.
    /// - Parameter identifier: The source identifier for this decoded image.
    /// - Parameter image: The decoded image data.
    /// - Parameter timestamp: The timestamp for this image.
    /// - Parameter orientation: The source orientation of this image.
    /// - Parameter verticalMirror: True if this image is intended to be vertically mirrored.
    typealias DecodedImageCallback = (_ identifier: UInt32,
                                      _ image: CIImage,
                                      _ timestamp: CMTimeValue,
                                      _ orientation: AVCaptureVideoOrientation?,
                                      _ verticalMirror: Bool) -> Void

    /// Represents an decoded audio sample.
    /// - Parameter identifier: The source identifier for this encoded image.
    /// - Parameter buffer: The buffer being decoded
    typealias DecodedAudioCallback = (_ identifier: UInt32,
                                      _ buffer: AVAudioPCMBuffer) -> Void

    private var encodedSampleCallback: EncodedImageCallback!
    private var encodedBufferCallback: EncodedAudioCallback!
    private var decodedSampleCallback: DecodedImageCallback!
    private var decodedBufferCallback: DecodedAudioCallback!

    func registerEncoderSampleCallback(callback: @escaping EncodedImageCallback) {
        encodedSampleCallback = callback
    }

    func registerEncoderBufferCallback(callback: @escaping EncodedAudioCallback) {
        encodedBufferCallback = callback
    }

    func registerDecoderSampleCallback(callback: @escaping DecodedImageCallback) {
        decodedSampleCallback = callback
    }

    func registerDecoderBufferCallback(callback: @escaping DecodedAudioCallback) {
        decodedBufferCallback = callback
    }

    /// Creates an encoder from a factory callback.
    /// - Parameter sourceId: The identifier for the source to encode.
    /// - Parameter config: The codec config information to use to create the encoder.
    func createEncoder(sourceId: UInt32, config: CodecConfig) -> Encoder {
        guard let factory = encoderFactories[config.codec] else {
            fatalError("No encoder factory found for codec type: \(config.codec)")
        }

        let encoder = factory(config)
        if let sampleEncoder = encoder as? SampleEncoder {
            sampleEncoder.registerCallback(callback: { sample in
                self.encodedSampleCallback(sourceId, sample)
            })
        } else if let bufferEncoder = encoder as? BufferEncoder {
            bufferEncoder.registerCallback(callback: { buffer in
                self.encodedBufferCallback(sourceId, buffer)
            })
        }

        return encoder
    }

    /// Creates an decoder from a factory callback.
    /// - Parameter sourceId: The identifier for the source to encode.
    /// - Parameter codec: The codec type of the decoder
    func createDecoder(sourceId: UInt32, codec: CodecType) -> Decoder {
        guard let factory = decoderFactories[codec] else {
            fatalError("No decoder factory found for codec type: \(codec)")
        }

        let decoder = factory()
        if let sampleDecoder = decoder as? SampleDecoder {
            sampleDecoder.registerCallback(callback: { image, timestamp, orientation, verticalMirror in
                self.decodedSampleCallback(sourceId, image, timestamp, orientation, verticalMirror)
            })
        } else if let bufferDecoder = decoder as? BufferDecoder {
            bufferDecoder.registerCallback(callback: { pcm, _ in
                self.decodedBufferCallback(sourceId, pcm)
            })
        }

        return decoder
    }
}
