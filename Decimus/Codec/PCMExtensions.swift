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

    func bytes() -> [UInt8] {
        return Array(UnsafeBufferPointer(self.audioBufferList.pointee.mBuffers))
    }
}

extension Array<UInt8> {
    mutating func toPCM(size: UInt32, format: AVAudioFormat) -> AVAudioPCMBuffer {
        return self.withUnsafeMutableBufferPointer { bytes -> AVAudioPCMBuffer in
            let buffer = AudioBuffer(
                mNumberChannels: format.channelCount,
                mDataByteSize: size * format.streamDescription.pointee.mBytesPerFrame,
                mData: bytes.baseAddress)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: buffer)
            return .init(pcmFormat: format, bufferListNoCopy: &bufferList)!
        }
    }
}
