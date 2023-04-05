import Foundation
import CoreImage
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
    /// - Parameter orientation: The source orientation of this image.
    /// - Parameter verticalMirror: True if this image is intended to be vertically mirrored.
    typealias DecodedImageCallback = (_ identifier: UInt32,
                                      _ image: CIImage,
                                      _ timestamp: CMTimeValue,
                                      _ orientation: AVCaptureVideoOrientation?,
                                      _ verticalMirror: Bool) -> Void

    /// Represents a decoded audio sample.
    typealias DecodedAudioCallback = (_ identifier: UInt32, _ buffer: AVAudioPCMBuffer) -> Void
    typealias DecodedAudio = (_ buffer: AVAudioPCMBuffer, _ timestamp: CMTime) -> Void

    private let imageCallback: DecodedImageCallback
    private let audioCallback: DecodedAudioCallback
    private let debugging: Bool
    private let errorWriter: ErrorWriter

    /// Managed pipeline elements.
    var encoders: [UInt32: EncoderElement] = .init()
    var decoders: [UInt32: DecoderElement] = .init()

    /// Create a new PipelineManager.
    init(
        decodedCallback: @escaping DecodedImageCallback,
        decodedAudioCallback: @escaping DecodedAudioCallback,
        debugging: Bool,
        errorWriter: ErrorWriter) {
        self.imageCallback = decodedCallback
        self.audioCallback = decodedAudioCallback
        self.debugging = debugging
        self.errorWriter = errorWriter
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

    func decode(mediaBuffer: MediaBufferFromSource) {
        debugPrint(message: "[\(mediaBuffer.source)] (\(mediaBuffer.media.timestampMs)) Decode write")
        let decoder: DecoderElement? = decoders[mediaBuffer.source]
        guard decoder != nil else { fatalError("Tried to decode for unregistered identifier: \(mediaBuffer.source)") }
        decoder!.decoder.write(data: mediaBuffer.media.buffer, timestamp: mediaBuffer.media.timestampMs)
    }

    func registerEncoder(identifier: UInt32, encoder: Encoder) {
        let element: EncoderElement = .init(identifier: identifier, encoder: encoder)
        encoders[identifier] = element
        debugPrint(message: "[\(identifier)] Registered encoder")
    }

    func registerDecoder(identifier: UInt32, type: MediaType) {
        let decoder: Decoder
        switch type {
        case .video:
            decoder = H264Decoder(callback: { decodedImage, presentation, orientation, verticalMirror in
                self.debugPrint(message: "[\(identifier)] (\(presentation)) Decoded")
                self.imageCallback(identifier, decodedImage, presentation, orientation, verticalMirror)
            })
        case .audio:
            let opusFormat: AVAudioFormat = .init(opusPCMFormat: .float32,
                                                  sampleRate: .opus48khz,
                                                  channels: 1)!
            decoder = LibOpusDecoder(format: opusFormat, fileWrite: false, errorWriter: errorWriter) { pcm, _ in
                self.audioCallback(identifier, pcm)
            }
        }

        let element: DecoderElement = .init(identifier: identifier, decoder: decoder)
        decoders[identifier] = element
        debugPrint(message: "[\(identifier)] Register decoder")
    }
}
