import CoreMedia
import AVFoundation

protocol Encoder {
    typealias EncodedBufferCallback = (MediaBuffer) -> Void
    func write(data: MediaBuffer)
    var callback: EncodedBufferCallback? {get set}
    mutating func registerCallback(callback: @escaping EncodedBufferCallback)
}

extension Encoder {
    mutating func registerCallback(callback: @escaping EncodedBufferCallback) {
        self.callback = callback
    }
}

actor EncoderMeasurement: Measurement {
    var name = "EncoderMeasurement"

    var fields: [Date?: [String: AnyObject]] = [:]
    var tags: [String: String] = [:]

    // Tag names.
    private let identifierTag = "identifier"
    private let codecTypeTag = "codecType"

    // Field names.
    private let writeField = "writes"
    private let bytesField = "bytesWritten"

    // Data.
    private var writes = 0
    private var bytesWritten = 0

    init(identifier: String, config: CodecConfig, submitter: MetricsSubmitter) {
        tags[identifierTag] = identifier
        tags[codecTypeTag] = "\(config.codec)"
        Task {
            await submitter.register(measurement: self)
        }
    }

    func write(bytes: Int) {
        self.writes += 1
        self.bytesWritten += bytes
        record(field: writeField, value: self.writes as AnyObject, timestamp: nil)
        record(field: bytesField, value: self.bytesWritten as AnyObject, timestamp: nil)
    }

    func record(field: String, value: AnyObject, timestamp: Date?) {
        if fields[timestamp] == nil {
            fields[timestamp] = [:]
        }
        fields[timestamp]![field] = value
    }
}
