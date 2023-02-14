import CoreMedia
import AVFoundation

class PassthroughEncoder: Encoder {

    private let callback: PipelineManager.DecodedAudio

    static var format: AVAudioFormat?
    static var samples: Int = 0

    init(callback: @escaping PipelineManager.DecodedAudio) {
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        Self.samples = sample.numSamples
        Self.format = .init(cmAudioFormatDescription: sample.formatDescription!)
        // Proves to/from sample buffer and media buffer works.
        let pcm: AVAudioPCMBuffer = .fromSample(sample: sample)
        callback(pcm)
//        callback(pcm.toSampleBuffer(presentationTime: sample.presentationTimeStamp).getMediaBuffer())
    }
}
