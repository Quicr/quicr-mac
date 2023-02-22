import AVFAudio

extension AVAudioPCMBuffer {
    func asFloat() -> AVAudioPCMBuffer {
        guard format.commonFormat == .pcmFormatInt16 else { fatalError("Must be of type Int16") }
        let newFormat: AVAudioFormat = .init(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: format.channelCount,
                                             interleaved: format.isInterleaved)!
        let float: AVAudioPCMBuffer = .init(pcmFormat: newFormat, frameCapacity: frameLength)!
        let src = int16ChannelData![0]
        let dest = float.floatChannelData![0]
        for frame in 0...Int(frameLength-1) {
            dest[frame] = Float(src[frame]) / Float(32768)
        }
        float.frameLength = frameLength
        return float
    }
}
