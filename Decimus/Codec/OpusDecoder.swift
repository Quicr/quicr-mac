import CoreMedia
import AVFoundation

class OpusDecoder: Decoder {

    private let callback: Encoder.EncodedSampleCallback
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let opus: AVAudioFormat

    init(callback: @escaping Encoder.EncodedSampleCallback) {
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
        outputFormat = .init(commonFormat: .pcmFormatFloat32,
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
            break
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
            let presentationTime: CMTime = .init(value: CMTimeValue(timestamp), timescale: 1000)
            callback(Self.sampleFromAudio(buffer: pcm, timestamp: presentationTime))
            return
        }
    }

    static func sampleFromAudio(buffer: AVAudioPCMBuffer, timestamp: CMTime) -> CMSampleBuffer {
        // Calculate timing info.
        var time: CMSampleTimingInfo = .init(duration: .init(value: 1,
                                                             timescale: Int32(buffer.format.sampleRate)),
                                             presentationTimeStamp: timestamp,
                                             decodeTimeStamp: CMTime.invalid)

        // Create new sample.
        var sample: CMSampleBuffer?
        let sampleError = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                               dataBuffer: nil,
                                               dataReady: false,
                                               makeDataReadyCallback: nil,
                                               refcon: nil,
                                               formatDescription: buffer.format.formatDescription,
                                               sampleCount: CMItemCount(buffer.frameLength),
                                               sampleTimingEntryCount: 1,
                                               sampleTimingArray: &time,
                                               sampleSizeEntryCount: 0,
                                               sampleSizeArray: nil,
                                               sampleBufferOut: &sample)
        guard sampleError == .zero else { fatalError() }

        // Set sample's data from audio buffer.
        let setError = CMSampleBufferSetDataBufferFromAudioBufferList(sample!,
                                                       blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                       flags: 0,
                                                       bufferList: buffer.mutableAudioBufferList)
        guard setError == .zero else { fatalError() }

        return sample!
    }
}
