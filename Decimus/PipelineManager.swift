import Foundation
import CoreImage
import CoreMedia
import AVFoundation

/// Manages pipeline elements.
class PipelineManager {
    private let errorWriter: ErrorWriter
    private let metricsSubmitter: MetricsSubmitter

    /// Managed pipeline elements.
    private var encoders: [UInt32: [Encoder]] = [:]
    var decoders: [UInt32: [UInt8: Decoder]] = [:]

    /// Create a new PipelineManager.
    init(errorWriter: ErrorWriter, metricsSubmitter: MetricsSubmitter) {
        self.errorWriter = errorWriter
        self.metricsSubmitter = metricsSubmitter
    }

    func registerEncoder(sourceId: UInt32, config: CodecConfig) {
        let encoder = CodecFactory.shared.createEncoder(sourceId: sourceId, config: config)
        guard encoders[sourceId] != nil else {
            encoders[sourceId] = [encoder]
            return
        }
        encoders[sourceId]!.append(encoder)
    }

    func registerDecoder(sourceId: UInt32, mediaId: UInt8, codec: CodecType) {
        let decoder = CodecFactory.shared.createDecoder(sourceId: sourceId, codec: codec)
        guard decoders[sourceId] != nil else {
            decoders[sourceId] = [mediaId: decoder]
            return
        }
        decoders[sourceId]![mediaId] = decoder
    }

    func unregisterEncoders(sourceId: UInt32) {
        encoders.removeValue(forKey: sourceId)
    }

    func unregisterDecoders(sourceId: UInt32) {
        decoders.removeValue(forKey: sourceId)
    }

    func encode(identifier: UInt32, sample: CMSampleBuffer) {
        guard let encoders = encoders[identifier] else {
            fatalError("Tried to encode for unregistered identifier: \(identifier)")
        }

        encoders.forEach { encoder in
            encoder.write(sample: sample)
        }
    }

    func decode(mediaBuffer: MediaBufferFromSource) {
        guard let decoders = decoders[mediaBuffer.source] else {
            fatalError("Tried to decode for unregistered identifier: \(mediaBuffer.source)")
        }

        decoders.forEach { _, decoder in
            decoder.write(data: mediaBuffer.media.buffer, timestamp: mediaBuffer.media.timestampMs)
        }
    }
}
