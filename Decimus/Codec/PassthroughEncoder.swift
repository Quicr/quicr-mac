import CoreMedia
import AVFoundation

class PassthroughEncoder: Encoder {

    private let callback: EncodedDataCallback

    static var format: AudioStreamBasicDescription?
    static var samples: Int = 0

    init(callback: @escaping EncodedDataCallback) {
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        var encoded: CMSampleBuffer?
        Self.samples = sample.numSamples
        Self.format = sample.formatDescription!.audioStreamBasicDescription!
        let createError = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault,
                                                   sampleBuffer: sample,
                                                   sampleBufferOut: &encoded)
        guard createError == .zero else { fatalError() }
        callback(encoded!)
    }
}
