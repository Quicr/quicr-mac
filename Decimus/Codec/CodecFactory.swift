import AVFoundation
import CoreImage
import Foundation

/// Codec type mappings.
enum CodecType: UInt8, CaseIterable {
    // Video
    case h264
    case av1

    // Audio
    case opus
    case xcodec
}

/// Possible media types that the pipeline understands.
enum MediaType { case audio; case video }

/// Abstract configuration for initialising codecs.
protocol CodecConfig {
    var codec: CodecType {get}
    var bitrate: UInt32 {get}
}

/// Video codec specific configuration type.
struct VideoCodecConfig: CodecConfig {
    let codec: CodecType
    let bitrate: UInt32
    let fps: UInt16
    let width: Int32
    let height: Int32
}

/// Audio codec specific configuration type.
struct AudioCodecConfig: CodecConfig {
    let codec: CodecType
    let bitrate: UInt32
}

class CodecFactory {
    static var shared: CodecFactory!

    /// Create a codec config from a quality profile string.
    /// - Parameter qualityProfile The quality profile string provided by the manifest.
    /// - Returns The corresponding codec config.
    static func makeCodecConfig(from qualityProfile: String) -> CodecConfig {
        let elements = qualityProfile.components(separatedBy: ",")

        guard let codec = CodecType.allCases.first(where: {
            String(describing: $0) == elements[0]
        }) else { fatalError() }

        var tokens: [String: String] = [:]
        for token in elements.dropFirst() {
            let subtokens = token.components(separatedBy: "=")
            tokens[subtokens[0]] = subtokens[1]
        }

        return makeCodecConfig(codec: codec, tokens: tokens)
    }

    /// Create a codec config from a dictionary of string tokens.
    /// - Parameter codec The codec type of the config.
    /// - Parameter tokens The dictionary of already parsed tokens.
    /// - Returns The corresponding codec config.
    static func makeCodecConfig(codec: CodecType, tokens: [String: String]) -> CodecConfig {
        switch codec {
        case .h264, .av1:
            return VideoCodecConfig(codec: codec, tokens: tokens)
        case .opus, .xcodec:
            return AudioCodecConfig(codec: codec, tokens: tokens)
        }
    }

    private var encoderFactories: [CodecType: (CodecConfig) -> Encoder] = [
        .h264: { config in
            guard let config = config as? VideoCodecConfig else { fatalError() }
            return H264Encoder(config: config, verticalMirror: false)
        },
        .av1: { config in
            guard let config = config as? VideoCodecConfig else { fatalError() }
            return H264Encoder(config: config, verticalMirror: false)
        },
        .opus: { _ in return LibOpusEncoder() },
        .xcodec: { _ in return LibOpusEncoder() }
    ]

    private var decoderFactories: [CodecType: (CodecConfig) -> Decoder] = [
        .h264: {
            guard let config = $0 as? VideoCodecConfig else { fatalError() }
            return H264Decoder(config: config)
        },
        .av1: {
            guard let config = $0 as? VideoCodecConfig else { fatalError() }
            return H264Decoder(config: config)
        },
        .opus: { _ in
            let opusFormat = AVAudioFormat(opusPCMFormat: .float32,
                                           sampleRate: .opus48khz,
                                           channels: 1)!
            return LibOpusDecoder(format: opusFormat)
        },
        .xcodec: { _ in
            let opusFormat = AVAudioFormat(opusPCMFormat: .float32,
                                           sampleRate: .opus48khz,
                                           channels: 1)!
            return LibOpusDecoder(format: opusFormat)
        }
    ]

    /// Represents an encoded image.
    /// - Parameter identifier: The source identifier for this encoded image.
    /// - Parameter sample: The sample being encoded
    typealias EncodedImageCallback = (_ identifier: UInt64,
                                      _ sample: CMSampleBuffer) -> Void

    /// Represents an encoded audio sample.
    /// - Parameter identifier: The source identifier for this encoded image.
    /// - Parameter buffer: The buffer being encoded
    typealias EncodedAudioCallback = (_ identifier: UInt64,
                                      _ buffer: MediaBuffer) -> Void

    /// Represents a decoded image.
    /// - Parameter identifier: The source identifier for this decoded image.
    /// - Parameter image: The decoded image data.
    /// - Parameter timestamp: The timestamp for this image.
    /// - Parameter orientation: The source orientation of this image.
    /// - Parameter verticalMirror: True if this image is intended to be vertically mirrored.
    typealias DecodedImageCallback = (_ identifier: UInt64,
                                      _ image: CIImage,
                                      _ timestamp: CMTimeValue,
                                      _ orientation: AVCaptureVideoOrientation?,
                                      _ verticalMirror: Bool) -> Void

    /// Represents an decoded audio sample.
    /// - Parameter identifier: The source identifier for this encoded image.
    /// - Parameter buffer: The buffer being decoded
    typealias DecodedAudioCallback = (_ identifier: UInt64,
                                      _ buffer: AVAudioPCMBuffer) -> Void

    private var encodedSampleCallback: EncodedImageCallback!
    private var encodedBufferCallback: EncodedAudioCallback!
    private var decodedSampleCallback: DecodedImageCallback!
    private var decodedBufferCallback: DecodedAudioCallback!

    func registerEncoderCallback(callback: @escaping EncodedImageCallback) {
        encodedSampleCallback = callback
    }

    func registerEncoderCallback(callback: @escaping EncodedAudioCallback) {
        encodedBufferCallback = callback
    }

    func registerDecoderCallback(callback: @escaping DecodedImageCallback) {
        decodedSampleCallback = callback
    }

    func registerDecoderCallback(callback: @escaping DecodedAudioCallback) {
        decodedBufferCallback = callback
    }

    /// Creates an encoder from a factory callback.
    /// - Parameter sourceId: The identifier for the source to encode.
    /// - Parameter config: The codec config information to use to create the encoder.
    func createEncoder(identifier: UInt64, config: CodecConfig) -> Encoder {
        guard let factory = encoderFactories[config.codec] else {
            fatalError("No encoder factory found for codec type: \(config.codec)")
        }

        let encoder = factory(config)
        if let sampleEncoder = encoder as? SampleEncoder {
            sampleEncoder.registerCallback(callback: { sample in
                self.encodedSampleCallback(identifier, sample)
            })
        } else if let bufferEncoder = encoder as? BufferEncoder {
            bufferEncoder.registerCallback(callback: { buffer in
                self.encodedBufferCallback(identifier, buffer)
            })
        }

        return encoder
    }

    /// Creates an decoder from a factory callback.
    /// - Parameter sourceId: The identifier for the source to encode.
    /// - Parameter codec: The codec type of the decoder
    func createDecoder(identifier: UInt64, config: CodecConfig) -> Decoder {
        guard let factory = decoderFactories[config.codec] else {
            fatalError("No decoder factory found for codec type: \(config.codec)")
        }

        let decoder = factory(config)
        if let sampleDecoder = decoder as? SampleDecoder {
            sampleDecoder.registerCallback { image, timestamp, orientation, verticalMirror in
                self.decodedSampleCallback(identifier, image, timestamp, orientation, verticalMirror)
            }
        } else if let bufferDecoder = decoder as? BufferDecoder {
            bufferDecoder.registerCallback { pcm, _ in
                self.decodedBufferCallback(identifier, pcm)
            }
        }

        return decoder
    }
}

/// Extentension initialiser for video codec configs from token dictionary.
extension VideoCodecConfig {
    init(codec: CodecType, tokens: [String: String]) {
        self.codec = codec
        self.bitrate = (UInt32(tokens["br"]!) ?? 0) * 1000
        self.fps = UInt16(tokens["fps"]!) ?? 0
        self.width = Int32(tokens["width"]!) ?? -1
        self.height = Int32(tokens["height"]!) ?? -1
    }
}

/// Extentension initialiser for audio codec configs from token dictionary.
extension AudioCodecConfig {
    init(codec: CodecType, tokens: [String: String]) {
        self.codec = codec
        self.bitrate = (UInt32(tokens["br"]!) ?? 0) * 1000
    }
}
