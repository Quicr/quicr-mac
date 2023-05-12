import CoreMedia
import AVFoundation

protocol Encoder {
    private let measurement: EncoderMeasurement
    func write(sample: CMSampleBuffer)
}

protocol SampleEncoder: Encoder {
    typealias EncodedSampleCallback = (CMSampleBuffer) -> Void
    var callback: EncodedSampleCallback? {get}

    func registerCallback(callback: @escaping EncodedSampleCallback)
    func write(sample: CMSampleBuffer)
}

protocol BufferEncoder: Encoder {
    typealias EncodedBufferCallback = (MediaBuffer) -> Void
    var callback: EncodedBufferCallback? {get}

    func registerCallback(callback: @escaping EncodedBufferCallback)
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
