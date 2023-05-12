import CoreMedia
import AVFoundation

class PassthroughEncoder: SampleEncoder {
    internal var callback: EncodedSampleCallback?

    func registerCallback(callback: @escaping EncodedSampleCallback) {
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        guard let callback = callback else { fatalError("Callback not set for encoder") }
        callback(sample)
    }
}
