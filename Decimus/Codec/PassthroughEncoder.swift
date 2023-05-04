import CoreMedia
import AVFoundation

class PassthroughEncoder: SampleEncoder {
    internal var callback: EncodedSampleCallback = { _ in }

    func registerCallback(callback: @escaping EncodedSampleCallback) {
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        callback(sample)
    }
}
