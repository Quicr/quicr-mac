import CoreMedia
import AVFoundation
import CoreAudio

class AudioEncoder: Encoder {

    // A sample is a single value
    // A frame is a collection of samples for the same time value (i.e frames = sample * channels).
    // A packet is the smallest possible collection of frames for given format. PCM=1, Opus=20ms?

    private static let audioBufferSize = 1000
    private var converter: AVAudioConverter?
    private let callback: EncodedDataCallback
    private var currentFormat: AVAudioFormat?
    private var inputBuffers: UnsafeMutableAudioBufferListPointer =
        AudioBufferList.allocate(maximumBuffers: audioBufferSize)
    private var inputBytesAvailable = 0
    private let targetFormat: AVAudioFormat
    private var writeIndex = 0
    private var readIndex = 0
    private var readByteOffset = 0

    init(to targetFormat: AVAudioFormat, callback: @escaping EncodedDataCallback) {
        self.targetFormat = targetFormat
        self.callback = callback
    }

    func write(sample: CMSampleBuffer) {
        // Ensure format exists and no change.
        guard sample.formatDescription != nil else { fatalError() }
        let format: AVAudioFormat = .init(cmAudioFormatDescription: sample.formatDescription!)
        if currentFormat != nil && format != currentFormat {
            fatalError()
        }

        // Make a converter if we need one.
        if converter == nil {
            let created: AVAudioConverter? = .init(from: format, to: targetFormat)
            guard created != nil else { fatalError("Conversion not supported") }
            converter = created!
        }

        // Call once to get the required size.
        var bufferListSize: Int = 0
        let getSizeError = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil)
        guard getSizeError == .zero else { fatalError() }

        // Call again for the actual audio list.
        let listPtr = AudioBufferList.allocate(maximumBuffers: bufferListSize)
        var list = listPtr.unsafeMutablePointer.pointee
        var buffer: CMBlockBuffer?
        let getListError = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &buffer)
        guard getListError == .zero else { fatalError() }

        // Iterate through the new list, and add it to the current list.
        guard list.mNumberBuffers == 1 else { fatalError() }
        if writeIndex == Self.audioBufferSize {
            writeIndex = 0
        }
        inputBuffers[writeIndex] = list.mBuffers
        writeIndex += 1
        inputBytesAvailable += Int(list.mBuffers.mDataByteSize)

        // Try and convert.
        let outputBuffer: AVAudioCompressedBuffer = .init(format: targetFormat,
                                                          packetCapacity: 1,
                                                          maximumPacketSize: converter!.maximumOutputPacketSize)

        var error: NSError?
        let status = converter!.convert(to: outputBuffer,
                                        error: &error) { packetCount, outStatus in
            return self.doConversion(from: format, packetCount: packetCount, outStatus: outStatus)
        }
        guard error == nil else { fatalError() }

        // Conversion status.
        if status == .haveData || status == .inputRanDry && outputBuffer.byteLength > 0 {
            // Callback the encoded data.
            callback(sampleFromAudio(buffer: outputBuffer))
            return
        }
    }

    func doConversion(from format: AVAudioFormat,
                      packetCount: AVAudioPacketCount,
                      outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        let bytesPerPacket = format.formatDescription.audioStreamBasicDescription!.mBytesPerPacket
        var requiredBytes = packetCount * bytesPerPacket

        // Ensure we have enough data.
        guard self.inputBytesAvailable >= requiredBytes else {
            outStatus.pointee = .noDataNow
            return .init()
        }

        // Collect the required data.
        let data: UnsafeMutableRawPointer = .allocate(byteCount: Int(requiredBytes),
                                                      alignment: MemoryLayout<UInt8>.alignment)
        let submissionBuffer: AudioBuffer = .init(mNumberChannels: format.channelCount,
                                                  mDataByteSize: requiredBytes,
                                                  mData: data)
        var submissionList: AudioBufferList = .init(mNumberBuffers: 1, mBuffers: submissionBuffer)

        // Try and collect the required data from available input.
        for _ in 0...Self.audioBufferSize {
            // Get some data from the next read buffer.
            let target = self.inputBuffers[self.readIndex]
            var bytesLeft: Int = Int(target.mDataByteSize)
            if readByteOffset != 0 {
                bytesLeft -= readByteOffset
            }
            let bytesToTake = min(Int(requiredBytes), bytesLeft)
            let ptr: UnsafePointer<UInt8> = UnsafePointer<UInt8>(target.mData!.assumingMemoryBound(to: UInt8.self))
            data.copyMemory(from: ptr + readByteOffset, byteCount: bytesToTake)

            // Record what we took.
            requiredBytes -= UInt32(bytesToTake)
            self.inputBytesAvailable -= bytesToTake

            // Handle partial reads.
            if bytesToTake != target.mDataByteSize {
                readByteOffset = bytesToTake
            } else {
                readByteOffset = 0
                self.readIndex += 1
                if self.readIndex == Self.audioBufferSize {
                    self.readIndex = 0
                }
            }

            // Check if we've got enough.
            if requiredBytes == 0 {
                break
            }
        }
        guard requiredBytes == 0 else { fatalError() }

        let submissionPackage: AVAudioPCMBuffer = .init(pcmFormat: format, bufferListNoCopy: &submissionList) {_ in
            data.deallocate()
        }!
        outStatus.pointee = .haveData
        return submissionPackage
    }

    func sampleFromAudio(buffer: AVAudioCompressedBuffer) -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        let sampleError = CMSampleBufferCreate(allocator: nil,
                                               dataBuffer: nil,
                                               dataReady: true,
                                               makeDataReadyCallback: nil,
                                               refcon: nil,
                                               formatDescription: nil,
                                               sampleCount: CMItemCount(buffer.packetCount),
                                               sampleTimingEntryCount: 0,
                                               sampleTimingArray: nil,
                                               sampleSizeEntryCount: 0,
                                               sampleSizeArray: nil,
                                               sampleBufferOut: &sample)
        guard sampleError == .zero else { fatalError() }

        var block: CMBlockBuffer?
        let blockError = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                            memoryBlock: buffer.data,
                                                            blockLength: Int(buffer.byteLength),
                                                            blockAllocator: kCFAllocatorNull,
                                                            customBlockSource: nil,
                                                            offsetToData: 0,
                                                            dataLength: Int(buffer.byteLength),
                                                            flags: 0,
                                                            blockBufferOut: &block)
        guard blockError == .zero else { fatalError() }

        let setError = CMSampleBufferSetDataBuffer(sample!, newValue: block!)
        guard setError == .zero else { fatalError() }

        return sample!
    }

//    func makeConverter(native: AVAudioFormat) -> AVAudioConverter {
//        // Setup a converter from native to Opus.
//        let opusFrameSize: UInt32 = 960
//        let opusSampleRate: Float64 = 48000.0
//        var opusDesc: AudioStreamBasicDescription = .init(mSampleRate: opusSampleRate,
//                                                          mFormatID: kAudioFormatOpus,
//                                                          mFormatFlags: 0,
//                                                          mBytesPerPacket: 0,
//                                                          mFramesPerPacket: opusFrameSize,
//                                                          mBytesPerFrame: 0,
//                                                          mChannelsPerFrame: 1,
//                                                          mBitsPerChannel: 0,
//                                                          mReserved: 0)
//        opus = .init(streamDescription: &opusDesc)!
//        let converter: AVAudioConverter? = .init(from: native, to: format)
//        guard converter != nil else { fatalError("Conversion not supported") }
//        return converter!
//    }
}
