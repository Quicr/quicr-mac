import CoreMedia

protocol Encoder {
    typealias EncodedSampleCallback = (CMSampleBuffer) -> Void
    typealias MediaCallback = (MediaBuffer) -> Void
    typealias SourcedMediaCallback = (MediaBufferFromSource) -> Void
    func write(sample: CMSampleBuffer)
}

actor EncoderMeasurement: Measurement {
    var name = "EncoderMeasurement"

    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String] = []

    private let writeField = "writes"
    private var writes = 0

    init(identifier: String, submitter: MetricsSubmitter) {
        tags.append(identifier)
        Task {
            await submitter.register(measurement: self)
        }
    }

    func write() {
        writes += 1
        record(field: writeField, value: writes as AnyObject, timestamp: nil)
    }

    func record(field: String, value: AnyObject, timestamp: Date?) {
        if fields[timestamp] == nil {
            fields[timestamp] = [:]
        }
        fields[timestamp]![field] = value
    }
}

/// Represents a single encoder in the pipeline.
class EncoderElement {
    /// Identifier of this stream.
    let identifier: UInt32
    /// Instance of the decoder.
    private let encoder: Encoder
    // Metrics.
    private let measurement: EncoderMeasurement

    /// Create a new encoder pipeline element.
    init(identifier: UInt32, encoder: Encoder, submitter: MetricsSubmitter) {
        self.identifier = identifier
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
