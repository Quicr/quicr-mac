import Foundation

protocol Decoder {
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32)
}

/// Represents a single element in the pipeline.
class DecoderElement {
    /// Identifier of this stream.
    let identifier: UInt32
    /// Instance of the decoder.
    let decoder: Decoder

    /// Create a new pipeline element
    init(identifier: UInt32, decoder: Decoder) {
        self.identifier = identifier
        self.decoder = decoder
    }
}
