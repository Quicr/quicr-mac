import CoreMedia

class OpusDecoder: Decoder {

    private let callback: Encoder.EncodedDataCallback

    init(callback: @escaping Encoder.EncodedDataCallback) {
        self.callback = callback
    }

    func write(data: UnsafePointer<UInt8>, length: Int, timestamp: UInt32) {
        let raw: UnsafeRawPointer = .init(data)
        let sample = raw.load(as: CMSampleBuffer.self)
        self.callback(sample)
    }

}
