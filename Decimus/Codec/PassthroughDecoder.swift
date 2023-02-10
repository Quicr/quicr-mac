import CoreMedia

class PassthroughDecoder: Decoder {

    private let callback: Encoder.EncodedDataCallback
    private let format: CMFormatDescription

    init(format: CMFormatDescription, callback: @escaping Encoder.EncodedDataCallback) {
        self.format = format
        self.callback = callback
    }

    func write(data: UnsafePointer<UInt8>, length: Int, timestamp: UInt32) {
        let buffer: MediaBuffer = .init(identifier: 0, buffer: data, length: length, timestampMs: timestamp)
        callback(buffer.toSample(format: format, samples: Int(timestamp)))
    }
}
