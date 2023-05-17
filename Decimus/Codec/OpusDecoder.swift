import CoreMedia
import AVFoundation

class OpusDecoder: BufferDecoder {

    internal var callback: DecodedBufferCallback?
    private let converter: AVAudioConverter
    private let opus: AVAudioFormat
    private let output: AVAudioFormat

    init(output: AVAudioFormat) {
        self.output = output
        var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: Double(48000),
                                                          mFormatID: kAudioFormatOpus,
                                                          mFormatFlags: 0,
                                                          mBytesPerPacket: 0,
                                                          mFramesPerPacket: 1,
                                                          mBytesPerFrame: 0,
                                                          mChannelsPerFrame: 2,
                                                          mBitsPerChannel: 0,
                                                          mReserved: 0)
        opus = .init(streamDescription: &opusDesc)!
        converter = .init(from: opus, to: output)!
    }

    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) {
        guard let callback = callback else { fatalError("Callback not set for decoder") }

        let pcm: AVAudioPCMBuffer = .init(pcmFormat: output,
                                          frameCapacity: 960)!
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
            let timestamp: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1000)
            callback(pcm, timestamp)
        }
    }
}
