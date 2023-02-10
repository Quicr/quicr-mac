import CoreMedia

extension CMSampleBuffer {
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
        let uint8Ptr: UnsafePointer<UInt8> = .init(copy.baseAddress!.assumingMemoryBound(to: UInt8.self))

        // Length & data.
//        var length: Int = 0
//        var charPtr: UnsafeMutablePointer<CChar>?
//        let getPointerError = CMBlockBufferGetDataPointer(self.dataBuffer!,
//                                                          atOffset: 0,
//                                                          lengthAtOffsetOut: nil,
//                                                          totalLengthOut: &length,
//                                                          dataPointerOut: &charPtr)
//        guard getPointerError == .zero else { fatalError() }

        // Pointer casts.
        // let raw: UnsafeRawPointer = .init(charPtr!)
        // let uint8Ptr: UnsafePointer<UInt8> = raw.assumingMemoryBound(to: UInt8.self)
        return .init(identifier: identifier, buffer: uint8Ptr, length: dataBuffer!.dataLength, timestampMs: timestampMs)
    }
}

extension MediaBuffer {
    func toSample(format: CMFormatDescription) -> CMSampleBuffer {
        var buffer: CMBlockBuffer?
        let blockError = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                            memoryBlock: .init(mutating: self.buffer),
                                                            blockLength: self.length,
                                                            blockAllocator: kCFAllocatorNull,
                                                            customBlockSource: nil,
                                                            offsetToData: 0,
                                                            dataLength: self.length,
                                                            flags: 0,
                                                            blockBufferOut: &buffer)
        guard blockError == .zero else { fatalError() }

        var timing: CMSampleTimingInfo = .init(duration: .init(value: 1,
                                                               timescale: CMTimeScale(
                                                                format.audioStreamBasicDescription!.mSampleRate
                                                               )),
                                               presentationTimeStamp: CMTime.invalid,
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
