import Foundation

/// Represents a single element in the pipeline.
class DecoderElement: Identifiable {
    /// Identifier of this stream.
    let identifier: UInt32
    /// Instance of the decoder.
    let decoder: Decoder
    /// Callback of decoded image.
    let callback: PipelineManager.PipelineCallback
    
    /// Create a new pipeline element
    init(identifier: UInt32, decoder: Decoder, callback: @escaping PipelineManager.PipelineCallback) {
        self.identifier = identifier
        self.decoder = decoder
        self.callback = callback
    }
}
