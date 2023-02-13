import CoreMedia
import AVFoundation

class PassthroughEncoder: Encoder {

    private let callback: EncodedBufferCallback

    static var format: AudioStreamBasicDescription?
    static var samples: Int = 0

    init(callback: @escaping EncodedBufferCallback) {
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        Self.samples = sample.numSamples
        Self.format = sample.formatDescription!.audioStreamBasicDescription!
        // Proves to/from sample buffer and media buffer works.
        let pcm: AVAudioPCMBuffer = .fromSample(sample: sample)
        callback(pcm.toSampleBuffer(presentationTime: sample.presentationTimeStamp).getMediaBuffer())
    }
}
