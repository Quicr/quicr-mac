import Foundation
import CoreGraphics
import CoreMedia

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
    private let encodedAudioCallback: EncodedSampleCallback
    private let debugging: Bool

    /// Managed pipeline elements.
    var encoders: [UInt32: EncoderElement] = .init()
    var decoders: [UInt32: DecoderElement] = .init()

    /// Create a new PipelineManager.
    init(
        decodedCallback: @escaping DecodedImageCallback,
        encodedCallback: @escaping EncodedSampleCallback,
        decodedAudioCallback: @escaping DecodedAudioCallback,
        encodedAudioCallback: @escaping EncodedSampleCallback,
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

    func decode(identifier: UInt32, data: UnsafePointer<UInt8>, length: Int, timestamp: UInt32) {
        debugPrint(message: "[\(identifier)] (\(timestamp)) Decode write")
        let decoder: DecoderElement? = decoders[identifier]
        guard decoder != nil else { fatalError("Tried to decode for unregistered identifier: \(identifier)") }
        decoder?.decoder.write(data: data, length: length, timestamp: timestamp)
    }

    func registerEncoder(identifier: UInt32, width: Int32, height: Int32) {
        let encoder = H264Encoder(width: width, height: height, callback: { sample in
            self.debugPrint(message: "[\(identifier)] (timestamp) Encoded")
            self.encodedCallback(identifier, sample)
        })
        registerEncoder(identifier: identifier, encoder: encoder)
    }

    func registerEncoder(identifier: UInt32) {
        let encoder = OpusEncoder { sample in
            self.encodedAudioCallback(identifier, sample)
        }
        registerEncoder(identifier: identifier, encoder: encoder)
    }

    private func registerEncoder(identifier: UInt32, encoder: Encoder) {
        let element: EncoderElement = .init(identifier: identifier, encoder: encoder)
        encoders[identifier] = element
        debugPrint(message: "[\(identifier)] Registered encoder")
    }

    func registerDecoder(identifier: UInt32, type: MediaType) {
        let decoder: Decoder
        switch type {
        case .video:
            decoder = H264Decoder(callback: { decodedImage, presentation in
                self.debugPrint(message: "[\(identifier)] (\(presentation)) Decoded")
                self.imageCallback(identifier, decodedImage, presentation)
            })
        case .audio:
            decoder = OpusDecoder(callback: { sample in
                self.audioCallback(identifier, sample)
            })
        }

        let element: DecoderElement = .init(identifier: identifier, decoder: decoder)
        decoders[identifier] = element
        debugPrint(message: "[\(identifier)] Register decoder")
    }
}
