import CoreMedia
import AVFoundation

extension CMSampleBuffer {

    func getMediaBuffer(source: UInt64, userData: AnyObject? = nil) -> MediaBufferFromSource {
        .init(source: source, media: self.getMediaBuffer(userData: userData))
    }

    func getMediaBuffer(userData: AnyObject? = nil) -> MediaBuffer {
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
        return .init(buffer: .init(copy), timestampMs: timestampMs, userData: userData)
    }

    func asMediaBuffer() -> MediaBuffer {
        let opaque = Unmanaged.passRetained(self).toOpaque()
        let bufferPtr: UnsafeRawBufferPointer = .init(start: opaque, count: 1)
        return .init(buffer: bufferPtr, timestampMs: 0)
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

        var bpp = Int(format.audioStreamBasicDescription!.mBytesPerPacket)
        if bpp == 0 {
            bpp = buffer!.dataLength
        }
        let sampleCount = buffer!.dataLength / bpp
        var sampleBuffer: CMSampleBuffer?
        let sampleError = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                               dataBuffer: buffer!,
                                               dataReady: true,
                                               makeDataReadyCallback: nil,
                                               refcon: nil,
                                               formatDescription: format,
                                               sampleCount: sampleCount,
                                               sampleTimingEntryCount: 1,
                                               sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1,
                                               sampleSizeArray: &bpp,
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
        do {
            try sample.copyPCMData(fromRange: 0..<sample.numSamples, into: buffer.mutableAudioBufferList)
        } catch {
            fatalError(error.localizedDescription)
        }
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

    func asMediaBuffer(timestampMs: UInt32, userData: AnyObject? = nil) -> MediaBuffer {
        guard format.channelCount == 1 else { fatalError() }
        let bpf = self.format.formatDescription.audioStreamBasicDescription!.mBytesPerFrame
        let lengthInBytes: Int = Int(bpf * self.frameLength)

        let data: Data
        if format.commonFormat == .pcmFormatFloat32 {
            data = .init(bytes: self.floatChannelData!.pointee, count: lengthInBytes)
        } else if format.commonFormat == .pcmFormatInt16 {
            data = .init(bytes: self.int16ChannelData!.pointee, count: lengthInBytes)
        } else {
            fatalError()
        }

        var buffer: MediaBuffer?
        data.withUnsafeBytes { ptr in
            buffer = .init(buffer: ptr, timestampMs: timestampMs, userData: userData)
        }
        return buffer!
    }

    static func fromMediaBuffer(buffer: MediaBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let bytesPerFrame = format.formatDescription.audioStreamBasicDescription!.mBytesPerFrame
        let pcm: AVAudioPCMBuffer = .init(pcmFormat: format,
                                          frameCapacity: UInt32(buffer.buffer.count) / bytesPerFrame)!
        let unsafePcm: UnsafeRawBufferPointer
        if format.commonFormat == .pcmFormatInt16 {
            let pcmPointer: UnsafeMutablePointer<Int16> = pcm.int16ChannelData![0]
            unsafePcm = .init(start: pcmPointer, count: buffer.buffer.count)
        } else if format.commonFormat == .pcmFormatFloat32 {
            let pcmPointer: UnsafeMutablePointer<Float> = pcm.floatChannelData![0]
            unsafePcm = .init(start: pcmPointer, count: buffer.buffer.count)
        } else {
            fatalError()
        }

        let pcmRawBuffer: UnsafeMutableRawBufferPointer = .init(mutating: unsafePcm)
        buffer.buffer.copyBytes(to: pcmRawBuffer)
        return pcm
    }
}
