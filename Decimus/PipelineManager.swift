import Foundation
import CoreGraphics
import CoreMedia

/// Manages pipeline elements.
class PipelineManager {
    
    /// Encoder or decoder.
    enum CodecType { case encoder; case decoder }
    
    /// Decoded image with source callback.
    typealias DecodedImageCallback = (UInt32, CGImage, CMTimeValue)->()
    
    /// Encoded data with source callback.
    typealias EncodedImageCallback = (UInt32, CMSampleBuffer) -> ()
    
    let imageCallback: DecodedImageCallback
    let encodedCallback: EncodedImageCallback
    let debugging: Bool
    
    /// Managed pipeline elements.
    var encoders: [UInt32: EncoderElement] = .init()
    var decoders: [UInt32: DecoderElement] = .init()
    
    /// Create a new PipelineManager.
    init(decodedCallback: @escaping DecodedImageCallback, encodedCallback: @escaping EncodedImageCallback, debugging: Bool) {
        self.imageCallback = decodedCallback
        self.encodedCallback = encodedCallback
        self.debugging = debugging
    }
    
    func debugPrint(message: String) {
        guard debugging else { return }
        print("Pipeline => \(message)")
    }
    
    func encode(identifier: UInt32, image: CVImageBuffer, timestamp: CMTime) {
        debugPrint(message: "[\(identifier)] (\(UInt32(timestamp.seconds * 1000))) Encode write")
        let encoder: EncoderElement? = encoders[identifier]
        guard encoder != nil else { fatalError("Tried to write for unregistered identifier: \(identifier)") }
        encoder!.encoder.write(image: image, timestamp: timestamp)
    }
    
    func decode(identifier: UInt32, data: UnsafePointer<UInt8>, length: Int, timestamp: UInt32) {
        debugPrint(message: "[\(identifier)] (\(timestamp)) Decode write")
        let decoder: DecoderElement? = decoders[identifier]
        guard decoder != nil else { fatalError("Tried to write for unregistered identifier: \(identifier)") }
        decoder?.decoder.write(data: data, length: length, timestamp: timestamp)
    }
    
    func registerEncoder(identifier: UInt32, width: Int32, height: Int32) {
        let encoder: Encoder = .init(width: width, height: height, callback: { sample in
            self.debugPrint(message: "[\(identifier)] (timestamp) Encoded")
            self.encodedCallback(identifier, sample)
        })
        let element: EncoderElement = .init(identifier: identifier, encoder: encoder)
        encoders[identifier] = element
        debugPrint(message: "[\(identifier)] Registered encoder")
    }
    
    func registerDecoder(identifier: UInt32) {
        let decoder: Decoder = .init(callback: { decodedImage, presentation in
            self.debugPrint(message: "[\(identifier)] (\(presentation)) Decoded")
            self.imageCallback(identifier, decodedImage, presentation)
        })
        let element: DecoderElement = .init(identifier: identifier, decoder: decoder)
        decoders[identifier] = element
        debugPrint(message: "[\(identifier)] Register decoder")
    }
}
