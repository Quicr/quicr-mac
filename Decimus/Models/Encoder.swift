import CoreMedia
import AVFoundation

protocol Encoder {
    func write(sample: CMSampleBuffer)
}

protocol SampleEncoder: Encoder {
    typealias EncodedSampleCallback = (CMSampleBuffer) -> Void
    var callback: EncodedSampleCallback? {get set}

    mutating func registerCallback(callback: @escaping EncodedSampleCallback)
}

extension SampleEncoder {
    mutating func registerCallback(callback: @escaping EncodedSampleCallback) {
        self.callback = callback
    }
}

protocol BufferEncoder: Encoder {
    typealias EncodedBufferCallback = (MediaBuffer) -> Void
    var callback: EncodedBufferCallback? {get set}

    mutating func registerCallback(callback: @escaping EncodedBufferCallback)
}

extension BufferEncoder {
    mutating func registerCallback(callback: @escaping EncodedBufferCallback) {
        self.callback = callback
    }
}

actor EncoderMeasurement: Measurement {
    var name = "EncoderMeasurement"

    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String] = []

    private let writeField = "writes"
    private var writes = 0

    init() {}

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
