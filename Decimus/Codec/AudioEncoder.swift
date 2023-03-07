import CoreMedia
import AVFoundation
import CoreAudio
import DequeModule

class AudioEncoder: Encoder {

    // A sample is a single value
    // A frame is a collection of samples for the same time value (i.e frames = sample * channels).
    // A packet is the smallest possible collection of frames for given format. PCM=1, Opus=20ms?

    private var converter: AVAudioConverter?
    private let callback: EncodedSampleCallback
    private var currentFormat: AVAudioFormat?
    // private var inputBuffers: Deque<CMSampleBuffer> = .init(minimumCapacity: 5)
    private let targetFormat: AVAudioFormat
    private var readByteOffset = 0

    init(to targetFormat: AVAudioFormat, callback: @escaping EncodedSampleCallback) {
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

        // inputBuffers.append(sample)

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
        let requiredBytesTotal = packetCount * bytesPerPacket
        var requiredBytes = requiredBytesTotal

        // Collect the required data.
        let data: UnsafeMutableRawPointer = .allocate(byteCount: Int(requiredBytesTotal),
                                                      alignment: MemoryLayout<UInt8>.alignment)
        let submissionBuffer: AudioBuffer = .init(mNumberChannels: format.channelCount,
                                                  mDataByteSize: requiredBytesTotal,
                                                  mData: data)
        var submissionList: AudioBufferList = .init(mNumberBuffers: 1, mBuffers: submissionBuffer)
        let submissionPackage: AVAudioPCMBuffer = .init(pcmFormat: format, bufferListNoCopy: &submissionList) {_ in
            data.deallocate()
        }!

        // Try and collect the required data from available input.
        var buffersToDrop = 0
        var indexToUse = 0
        var dataOffset = 0
        while requiredBytes > 0 {
            // Get some data from the first available sample.
//            if inputBuffers.isEmpty || inputBuffers.endIndex == indexToUse {
//                // When it's opus (at least?) we will not get
//                // any encoded data out for partial reads.
//                readByteOffset = 0
//                outStatus.pointee = .noDataNow
//                return submissionPackage
//            }
//            let target: CMSampleBuffer = inputBuffers[indexToUse]
            var lengthAtOffset: Int = 0
            var totalLength: Int = 0
            var ptr: UnsafeMutablePointer<CChar>?
//            let getPtr = CMBlockBufferGetDataPointer(target.dataBuffer!,
//                                                     atOffset: readByteOffset,
//                                                     lengthAtOffsetOut: &lengthAtOffset,
//                                                     totalLengthOut: &totalLength,
//                                                     dataPointerOut: &ptr)
//            guard getPtr == .zero else {
//                print("Asked for offset \(readByteOffset). Total length was: \(totalLength)")
//                fatalError(getPtr.description)
//            }

            // Get as much data as we need/can.
            let bytesToTake = min(Int(requiredBytes), lengthAtOffset)
            print("Bytes to take: \(bytesToTake)")
            guard lengthAtOffset >= bytesToTake else { fatalError() }
            let spaceLeft = Int(requiredBytesTotal) - dataOffset
            guard spaceLeft >= Int(bytesToTake) else { fatalError() }
            memcpy(data + dataOffset, ptr!, bytesToTake)
            dataOffset += bytesToTake
            if bytesToTake == lengthAtOffset {
                // We've taken all that's left, we need
                // to drop this buffer if we complete the full data.
                // But if not, we need to retain it for next reader.
                buffersToDrop += 1
                indexToUse += 1
                readByteOffset = 0
                print("Full read: \(bytesToTake)/\(lengthAtOffset)")
            } else if bytesToTake < lengthAtOffset {
                // We only partially read this buffer.
                print("Partial read of: \(bytesToTake)/\(lengthAtOffset)")
                print("Existing offset was: \(readByteOffset)/\(lengthAtOffset)")
                readByteOffset += bytesToTake
                print("Offset now: \(readByteOffset)/\(lengthAtOffset)")
            } else {
                fatalError("RICH CANT DO MATHS")
            }

            // Record what we took.
            requiredBytes -= UInt32(bytesToTake)
        }

        // Drop all the buffers we used up.
        for _ in 0...buffersToDrop {
            // _ = inputBuffers.popFirst()!
        }

        // We managed to supply enough data.
        outStatus.pointee = .haveData
        return submissionPackage
    }

    func sampleFromAudio(buffer: AVAudioCompressedBuffer) -> CMSampleBuffer {

        // Sanity checks.
        guard buffer.packetCount == 1 else {
            fatalError("Compressed audio expected to be 1 packet")
        }

        guard targetFormat == buffer.format else {
            fatalError("Received buffer had unexpected format")
        }

        // FIXME: Copying here while debugging, should be able to skip.
        var length: Int = Int(buffer.byteLength)
        let ptr: UnsafeMutableRawBufferPointer = .allocate(byteCount: length,
                                                           alignment: MemoryLayout<UInt8>.alignment)
        let data: UnsafeMutableRawPointer = buffer.data
        let uint8Data: UnsafePointer<UInt8> = .init(data.assumingMemoryBound(to: UInt8.self))
        let src: UnsafeRawBufferPointer = .init(start: .init(uint8Data), count: length)
        ptr.copyMemory(from: src)

        // Make a block buffer for the encoded data.
        var block: CMBlockBuffer?
        let blockError = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                            memoryBlock: ptr.baseAddress!,
                                                            blockLength: length,
                                                            blockAllocator: kCFAllocatorNull,
                                                            customBlockSource: nil,
                                                            offsetToData: 0,
                                                            dataLength: length,
                                                            flags: 0,
                                                            blockBufferOut: &block)
        guard blockError == .zero else { fatalError() }

        // Create the sample.
        var sample: CMSampleBuffer?
        let sampleError = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                               dataBuffer: block,
                                               dataReady: true,
                                               makeDataReadyCallback: nil,
                                               refcon: nil,
                                               formatDescription: targetFormat.formatDescription,
                                               sampleCount: 1,
                                               sampleTimingEntryCount: 0,
                                               sampleTimingArray: nil,
                                               sampleSizeEntryCount: 1,
                                               sampleSizeArray: &length,
                                               sampleBufferOut: &sample)
        guard sampleError == .zero else { fatalError() }

        return sample!
    }
}
