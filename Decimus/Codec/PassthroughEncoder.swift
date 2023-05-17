import CoreMedia
import AVFoundation

class PassthroughEncoder: SampleEncoder {
    internal var callback: EncodedSampleCallback?

    func write(sample: CMSampleBuffer) {
        guard let callback = callback else { fatalError("Callback not set for encoder") }
        callback(sample)
    }
}
