import CoreMedia
import AVFoundation

extension CMSampleBuffer {

    func getMediaBuffer() -> MediaBuffer {
        getMediaBuffer(identifier: 0)
    }

    func getMediaBuffer(identifier: UInt32) -> MediaBuffer {
        // Requires contiguous buffers.
        guard self.dataBuffer!.isContiguous else { fatalError() }

        // Timestamp.
        let timestampMs: UInt32 = UInt32(self.presentationTimeStamp.convertScale(1000, method: .default).value)

        // Copy.
        let copy: UnsafeMutableRawBufferPointer = .allocate(byteCount: self.dataBuffer!.dataLength,
                                                            alignment: MemoryLayout<UInt8>.alignment)
        do {
            try self.dataBuffer!.copyDataBytes(to: copy)
        } catch {
            copy.deallocate()
            fatalError()
        }
        return .init(identifier: identifier, buffer: .init(copy), timestampMs: timestampMs)
    }
}

extension MediaBuffer {
    func toSample(format: CMFormatDescription) -> CMSampleBuffer {
        var buffer: CMBlockBuffer?
        let blockError = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                            memoryBlock: .init(mutating: self.buffer.baseAddress),
                                                            blockLength: self.buffer.count,
                                                            blockAllocator: kCFAllocatorNull,
                                                            customBlockSource: nil,
                                                            offsetToData: 0,
                                                            dataLength: self.buffer.count,
                                                            flags: 0,
                                                            blockBufferOut: &buffer)
        guard blockError == .zero else { fatalError() }

        let duration: CMTime = .init(value: 1,
                                     timescale: CMTimeScale(format.audioStreamBasicDescription!.mSampleRate))
        let presentation: CMTime = .init(value: CMTimeValue(timestampMs), timescale: 1000)

        var timing: CMSampleTimingInfo = .init(duration: duration,
                                               presentationTimeStamp: presentation,
                                               decodeTimeStamp: CMTime.invalid)

        // TODO: How can this work when the samples etc. are wrong?
        var sampleLength = buffer!.dataLength
        var sampleBuffer: CMSampleBuffer?
        let sampleError = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                               dataBuffer: buffer!,
                                               dataReady: true,
                                               makeDataReadyCallback: nil,
                                               refcon: nil,
                                               formatDescription: format,
                                               sampleCount: 1,
                                               sampleTimingEntryCount: 1,
                                               sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1,
                                               sampleSizeArray: &sampleLength,
                                               sampleBufferOut: &sampleBuffer)
        guard sampleError == .zero else { fatalError() }
        return sampleBuffer!
    }
}

extension AVAudioPCMBuffer {
    static func fromSample(sample: CMSampleBuffer) -> AVAudioPCMBuffer {
        let format: AVAudioFormat = .init(cmAudioFormatDescription: sample.formatDescription!)
        let frames = AVAudioFrameCount(sample.numSamples)
        let buffer: AVAudioPCMBuffer = .init(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let error = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,
                                                                 at: 0,
                                                                 frameCount: Int32(frames),
                                                                 into: buffer.mutableAudioBufferList)
        guard error == .zero else { fatalError() }
        return buffer
    }

    func toSampleBuffer(presentationTime: CMTime) -> CMSampleBuffer {
        let timing: CMSampleTimingInfo = .init(duration: .init(value: 1,
                                                               timescale: CMTimeScale(self.format.sampleRate)),
                                               presentationTimeStamp: presentationTime,
                                               decodeTimeStamp: .invalid)
        let bpf: Int = Int(self.format.formatDescription.audioStreamBasicDescription!.mBytesPerFrame)
        let sample: CMSampleBuffer
        do {
            sample = try .init(dataBuffer: nil,
                               formatDescription: self.format.formatDescription,
                               numSamples: CMItemCount(self.frameLength),
                               sampleTimings: [timing],
                               sampleSizes: [bpf])
        } catch {
            fatalError(error.localizedDescription)
        }
        let error = CMSampleBufferSetDataBufferFromAudioBufferList(sample,
                                                       blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                       flags: 0,
                                                       bufferList: self.mutableAudioBufferList)
        guard error == .zero else { fatalError() }
        return sample
    }

    func asMediaBuffer(timestampMs: UInt32) -> MediaBuffer {
        guard format.channelCount == 1 else { fatalError() }
        let bpf = self.format.formatDescription.audioStreamBasicDescription!.mBytesPerFrame
        let lengthInBytes: Int = Int(bpf * self.frameLength)

        let formatId = format.formatDescription.audioStreamBasicDescription!.mFormatID
        if format.formatDescription.audioStreamBasicDescription!.mFormatID == kAudioFormatOpus {
            print("GOT SOME OPUS")
        }

        let data: Data = .init(bytes: self.int16ChannelData!.pointee, count: lengthInBytes)
        var buffer: MediaBuffer?
        data.withUnsafeBytes { ptr in
            buffer = .init(identifier: 0, buffer: ptr, timestampMs: timestampMs)
        }
        return buffer!
    }
}
