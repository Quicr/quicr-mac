import CoreMedia
import AVFoundation

class OpusDecoder: Decoder {

    private let callback: Encoder.EncodedBufferCallback
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let opus: AVAudioFormat

    init(callback: @escaping Encoder.EncodedBufferCallback) {
        self.callback = callback
        let opusFrameSize: UInt32 = 960
        let opusSampleRate: Float64 = 48000.0
        var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: opusSampleRate,
                                                          mFormatID: kAudioFormatOpus,
                                                          mFormatFlags: 0,
                                                          mBytesPerPacket: 0,
                                                          mFramesPerPacket: opusFrameSize,
                                                          mBytesPerFrame: 0,
                                                          mChannelsPerFrame: 1,
                                                          mBitsPerChannel: 0,
                                                          mReserved: 0)
        opus = .init(streamDescription: &opusDesc)!
        outputFormat = .init(commonFormat: .pcmFormatInt16,
                             sampleRate: Double(48000),
                             channels: 1,
                             interleaved: false)!
        converter = .init(from: opus, to: outputFormat)!
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        let opusAsbd = opus.formatDescription.audioStreamBasicDescription!
        let pcm: AVAudioPCMBuffer = .init(pcmFormat: outputFormat, frameCapacity: opusAsbd.mFramesPerPacket)!
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { packetCount, outStatus in
            // Do conversion.
            guard packetCount == 1 else { fatalError() }
            outStatus.pointee = .haveData
            let compressed: AVAudioCompressedBuffer = .init(format: self.opus,
                                                            packetCapacity: 1,
                                                            maximumPacketSize: data.count)
            compressed.packetCount = 1
            compressed.byteLength = UInt32(data.count)
            compressed.data.copyMemory(from: data.baseAddress!, byteCount: data.count)
            return compressed
        }
        guard error == nil else { fatalError() }

        switch status {
        case .haveData:
            print("Decoded Opus")
        case .error:
            fatalError()
        case .endOfStream:
            fatalError()
        case .inputRanDry:
            print("Input ran dry")
        default:
            fatalError()
        }

        if pcm.frameLength > 0 {
            callback(pcm.asMediaBuffer(timestampMs: timestamp))
        }
    }
}
