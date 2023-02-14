import AVFAudio

struct OpusSettings {
    static let targetFormat: AVAudioFormat = .init(commonFormat: .pcmFormatInt16,
                                                 sampleRate: Double(48000),
                                                 channels: 1,
                                                 interleaved: false)!
    static let opusFrameSize: AVAudioFrameCount = 480
}
