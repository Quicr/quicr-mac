import Foundation
import CoreGraphics
import CoreMedia

/// Manages pipeline elements.
class PipelineManager {
    
    /// Encoder or decoder.
    enum CodecType { case encoder; case decoder }
    
    /// Decoded image with source callback.
    typealias PipelineCallback = (UInt32, CGImage, CMTimeValue)->()
    let callback: PipelineCallback
    
    /// Managed pipeline elements.
    var elements: [UInt32: any Identifiable] = .init()
    
    /// Create a new PipelineManager.
    init(callback: @escaping PipelineCallback) {
        self.callback = callback
    }
    
    /// Register a new source.
    func register(identifier: UInt32, type: CodecType) {
        var element: any Identifiable
        switch type {
        case.encoder:
            element = EncoderElement(identifier: identifier, encoder: .init())
        case.decoder:
            element = DecoderElement(
                identifier: identifier,
                decoder: .init(callback: { decodedImage, presentation in
                    self.callback(identifier, decodedImage, presentation)
                }),
                callback: self.callback)
        }
        
        elements[identifier] = element
    }
}
