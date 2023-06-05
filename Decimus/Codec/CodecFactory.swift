import AVFoundation
import CoreImage
import Foundation

enum CodecError: Error {
    case noCodecFound(CodecType)
    case failedToCreateCodec(CodecType)
}

/// Codec type mappings.
enum CodecType: UInt8, CaseIterable {
    // Video
    case h264
    case av1

    // Audio
    case opus
    case xcodec
}

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
    let audioFormat: AVAudioFormat

    init(audioFormat: AVAudioFormat) {
        self.audioFormat = audioFormat
    }

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
}

class EncoderFactory: CodecFactory {
    private lazy var factories: [CodecType: (CodecConfig) -> Encoder] = [
        .h264: {
            guard let config = $0 as? VideoCodecConfig else { fatalError() }
            return H264Encoder(config: config, verticalMirror: false)
        },
        .opus: { [unowned self] in
            guard let config = $0 as? AudioCodecConfig else { fatalError() }
            do {
                return try LibOpusEncoder(format: self.audioFormat)
            } catch {
                fatalError()
            }
        }
    ]

    func create(_ config: CodecConfig,
                callback: @escaping Encoder.EncodedCallback) throws -> Encoder {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        var encoder = factory(config)
        encoder.registerCallback(callback: callback)
        return encoder
    }
}

class DecoderFactory: CodecFactory {
    private lazy var factories: [CodecType: (CodecConfig) -> Decoder] = [
        .h264: {
            guard let config = $0 as? VideoCodecConfig else { fatalError() }
            return H264Decoder(config: config)
        },
        .opus: { [unowned self] _ in
            do {
                // Decode directly into output format if possible.
                return try LibOpusDecoder(format: self.audioFormat)
            } catch {
                fatalError()
            }
        }
    ]

    override init(audioFormat: AVAudioFormat) {
        if audioFormat.isValidOpusPCMFormat {
            super.init(audioFormat: audioFormat)
        } else {
            super.init(audioFormat: .init(opusPCMFormat: .float32,
                                          sampleRate: .opus48khz,
                                          channels: 2)!)
        }
    }

    private func create<DecoderType>(config: CodecConfig) throws -> DecoderType {
        guard let factory = factories[config.codec] else {
            throw CodecError.noCodecFound(config.codec)
        }

        guard let decoder = factory(config) as? DecoderType else {
            throw CodecError.failedToCreateCodec(config.codec)
        }

        return decoder
    }

    func create(config: CodecConfig, callback: @escaping SampleDecoder.DecodedCallback) throws -> SampleDecoder {
        var decoder: SampleDecoder = try create(config: config)
        decoder.registerCallback(callback: callback)
        return decoder
    }

    func create(config: CodecConfig, callback: @escaping BufferDecoder.DecodedCallback) throws -> BufferDecoder {
        var decoder: BufferDecoder = try create(config: config)
        decoder.registerCallback(callback: callback)
        return decoder
    }
}

/// Extentension initialiser for video codec configs from token dictionary.
extension VideoCodecConfig {
    init(codec: CodecType, tokens: [String: String]) {
        self.codec = codec
        self.bitrate = (UInt32(tokens["br"] ?? "") ?? 0 ) * 1000
        self.fps = UInt16(tokens["fps"] ?? "") ?? 0
        self.width = Int32(tokens["width"] ?? "") ?? -1
        self.height = Int32(tokens["height"] ?? "") ?? -1
    }
}

/// Extentension initialiser for audio codec configs from token dictionary.
extension AudioCodecConfig {
    init(codec: CodecType, tokens: [String: String]) {
        self.codec = codec
        self.bitrate = (UInt32(tokens["br"] ?? "") ?? 0) * 1000
    }
}
