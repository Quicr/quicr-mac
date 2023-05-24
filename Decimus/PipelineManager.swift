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
    init(identifier: UInt64, encoder: Encoder, config: CodecConfig, submitter: MetricsSubmitter) {
        self.encoder = encoder
        measurement = .init(identifier: String(identifier), config: config, submitter: submitter)
    }

    func write(data: MediaBuffer) {
        let bytes = data.buffer.count
        self.encoder.write(data: data)
        Task {
            await measurement.write(bytes: bytes)
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

    func registerEncoder(identifier: UInt64,
                         config: CodecConfig,
                         encodeCallback: @escaping Encoder.EncodedBufferCallback) {
        guard let encoder = try? CodecFactory.shared.createEncoder(config, encodeCallback: encodeCallback) else {
            fatalError("Failed to create encoder")
        }

        guard encoders[identifier] == nil else { return }
        encoders[identifier] = .init(identifier: identifier,
                                     encoder: encoder,
                                     config: config,
                                     submitter: metricsSubmitter)
    }

    func registerDecoder(identifier: UInt64, config: CodecConfig) {
        guard let decoder = try? CodecFactory.shared.createDecoder(identifier: identifier, config: config) else {
            fatalError("Failed to create decoder")
        }
        guard decoders[identifier] == nil else {
            return
        }
    }

    func unregisterEncoder(identifier: UInt64) {
        encoders.removeValue(forKey: identifier)
    }

    func unregisterDecoder(identifier: UInt64) {
        decoders.removeValue(forKey: identifier)
    }

    func encode(identifier: UInt64, buffer: MediaBuffer) {
        guard let encoder = encoders[identifier] else {
            fatalError("Tried to encode for unregistered identifier: \(identifier)")
        }
        encoder.write(data: buffer)
    }

    func decode(identifier: UInt64, buffer: MediaBuffer) {
        guard let decoder = decoders[identifier] else {
            fatalError("Tried to decode for unregistered identifier: \(identifier)")
        }
        decoder.write(buffer: buffer)
    }
}
