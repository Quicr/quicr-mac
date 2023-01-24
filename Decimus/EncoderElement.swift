import Foundation

class Encoder {}

/// Represents a single encoder in the pipeline.
class EncoderElement: Identifiable {
    /// Identifier of this stream.
    let identifier: UInt32
    /// Instance of the decoder.
    let encoder: Encoder
    
    /// Create a new encoder pipeline element.
    init(identifier: UInt32, encoder: Encoder) {
        self.identifier = identifier
        self.encoder = encoder
    }
}
