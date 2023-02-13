import CoreMedia

class PassthroughDecoder: Decoder {

    private let callback: Encoder.EncodedSampleCallback
    private let format: CMFormatDescription

    init(format: CMFormatDescription, callback: @escaping Encoder.EncodedSampleCallback) {
        self.format = format
        self.callback = callback
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        let buffer: MediaBuffer = .init(identifier: 0, buffer: data, timestampMs: timestamp)
        callback(buffer.toSample(format: format))
    }
}
