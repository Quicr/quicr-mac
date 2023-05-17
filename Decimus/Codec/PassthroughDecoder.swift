import CoreMedia

class PassthroughDecoder: Decoder {

    private let callback: SampleEncoder.EncodedSampleCallback
    private let format: CMFormatDescription

    init(format: CMFormatDescription, callback: @escaping SampleEncoder.EncodedSampleCallback) {
        self.format = format
        self.callback = callback
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        let buffer: MediaBuffer = .init(buffer: data, timestampMs: timestamp)
        callback(buffer.toSample(format: format))
    }
}
