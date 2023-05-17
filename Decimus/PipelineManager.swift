import Foundation
import CoreImage
import CoreMedia
import AVFoundation

class EncoderWrapper {
    /// Instance of the Encoder
    private let encoder: Encoder
    /// Metrics.
    private let measurement: EncoderMeasurement

    /// Create a new encoder pipeline element.
    init(identifier: UInt64, encoder: Encoder, submitter: MetricsSubmitter) {
        self.encoder = encoder
        measurement = .init(identifier: String(identifier), submitter: submitter)
    }

    func write(sample: CMSampleBuffer) {
        self.encoder.write(sample: sample)
        Task {
            await measurement.write()
        }
    }
}

/// Manages pipeline elements.
class PipelineManager {
    private let errorWriter: ErrorWriter
    private let metricsSubmitter: MetricsSubmitter

    private var encoders: [UInt64: EncoderWrapper] = [:]
    var decoders: [UInt64: Decoder] = [:]

    /// Create a new PipelineManager.
    init(errorWriter: ErrorWriter, metricsSubmitter: MetricsSubmitter) {
        self.errorWriter = errorWriter
        self.metricsSubmitter = metricsSubmitter
    }

    func registerEncoder(identifier: UInt64, config: CodecConfig) {
        let encoder = CodecFactory.shared.createEncoder(identifier: identifier,
                                                        config: config,
                                                        metricsSubmitter: metricsSubmitter)
        guard encoders[identifier] == nil else {
            return
        }

        encoders[identifier] = .init(identifier: identifier, encoder: encoder, submitter: metricsSubmitter)
    }

    func registerDecoder(identifier: UInt64, config: CodecConfig) {
        let decoder = CodecFactory.shared.createDecoder(identifier: identifier, config: config)
        guard decoders[identifier] == nil else {
            return
        }
        decoders[identifier] = decoder
    }

    func unregisterEncoder(identifier: UInt64) {
        encoders.removeValue(forKey: identifier)
    }

    func unregisterDecoder(identifier: UInt64) {
        decoders.removeValue(forKey: identifier)
    }

    func encode(identifier: UInt64, sample: CMSampleBuffer) {
        guard let encoder = encoders[identifier] else {
            fatalError("Tried to encode for unregistered identifier: \(identifier)")
        }
        encoder.write(sample: sample)
    }

    func decode(mediaBuffer: MediaBufferFromSource) {
        guard let decoder = decoders[mediaBuffer.source] else {
            fatalError("Tried to decode for unregistered identifier: \(mediaBuffer.source)")
        }
        decoder.write(data: mediaBuffer.media.buffer, timestamp: mediaBuffer.media.timestampMs)
    }
}
