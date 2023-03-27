import VideoToolbox
import CoreVideo
import AVFoundation

class H264Encoder: Encoder {

    private let startCodeLength = 4
    private let startCode = [ 0x00, 0x00, 0x00, 0x01 ]

    private var encoder: VTCompressionSession?
    private let callback: EncodedSampleCallback

    private let fps: Int32 = 60
    private let bitrate: Int32 = 12
    private var orientation: AVCaptureVideoOrientation?
    private let verticalMirror: Bool

    init(width: Int32,
         height: Int32,
         orientation: AVCaptureVideoOrientation?,
         verticalMirror: Bool,
         callback: @escaping EncodedSampleCallback) {
        self.callback = callback
        self.orientation = orientation
        self.verticalMirror = verticalMirror

        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary

        let error = VTCompressionSessionCreate(allocator: nil,
                                               width: width,
                                               height: height,
                                               codecType: kCMVideoCodecType_H264,
                                               encoderSpecification: encoderSpecification,
                                               imageBufferAttributes: nil,
                                               compressedDataAllocator: nil,
                                               outputCallback: nil,
                                               refcon: nil,
                                               compressionSessionOut: &encoder)

        guard error == .zero else { fatalError("Encoder creation failed")}

        let realtimeError = VTSessionSetProperty(encoder!,
                                                 key: kVTCompressionPropertyKey_RealTime,
                                                 value: kCFBooleanTrue)
        guard realtimeError == .zero else { fatalError("Failed to set encoder to realtime") }

        VTSessionSetProperty(encoder!,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)

        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AverageBitRate, value: 2048000 as CFNumber)
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: fps * 5 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(encoder!)
    }

    deinit {
        guard let session = encoder else { return }
        VTCompressionSessionInvalidate(session)
        self.encoder = nil
    }

    func setOrientation(orientation: AVCaptureVideoOrientation) {
        self.orientation = orientation
    }

    func write(sample: CMSampleBuffer) {
        guard let compressionSession = encoder,
              let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        let error = VTCompressionSessionEncodeFrame(compressionSession,
                                                    imageBuffer: imageBuffer,
                                                    presentationTimeStamp: timestamp,
                                                    duration: .invalid,
                                                    frameProperties: nil,
                                                    infoFlagsOut: nil,
                                                    outputHandler: self.encoded)
        guard error == .zero else { fatalError("Encode write failure: \(error)")}
    }

    func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard status == .zero else { fatalError("Encode failure: \(status)")}
        guard let sample = sample else { return; }

        // Annex B time.
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
        var idr = false
        guard let sampleAttachments = attachments[0] as? NSDictionary else { fatalError("Failed to get attachements") }
        let key = kCMSampleAttachmentKey_NotSync as NSString
        if let found = sampleAttachments[key] as? Bool? {
            idr = !(found != nil && found == true)
        }

        if idr {
            do {
                // SPS + PPS.
                let parameterSets = try handleParameterSets(sample: sample)
                callback(parameterSets)
            } catch {
                print("Failed to handle parameter sets")
                return
            }
        }

        // Orientation SEI.
        if orientation != nil {
            let orientationSei = makeOrientationSEI(orientation: orientation!, verticalMirror: verticalMirror)
            callback(orientationSei)
        }

        let buffer = sample.dataBuffer!
        var offset = 0
        while offset < buffer.dataLength - startCodeLength {
            guard let memory = malloc(startCodeLength) else { fatalError("malloc fail") }
            var data: UnsafeMutablePointer<CChar>?
            let accessError = CMBlockBufferAccessDataBytes(buffer,
                                                           atOffset: offset,
                                                           length: startCodeLength,
                                                           temporaryBlock: memory,
                                                           returnedPointerOut: &data)
            guard accessError == .zero else { fatalError("Bad access") }
            guard data != nil else { fatalError("Bad access") }

            var naluLength: UInt32 = 0
            memcpy(&naluLength, data, startCodeLength)
            free(memory)
            naluLength = CFSwapInt32BigToHost(naluLength)

            // Replace with start code.
            let replaceError = CMBlockBufferReplaceDataBytes(with: startCode,
                                                             blockBuffer: buffer,
                                                             offsetIntoDestination: offset,
                                                             dataLength: startCodeLength)
            guard replaceError == .zero else { fatalError("Replace") }

            // TODO: This is broken.
            try? buffer.withUnsafeMutableBytes(atOffset: offset) { ptr in
                ptr[3] = 0x01
            }

            // Carry on.
            offset += startCodeLength + Int(naluLength)
        }

        // Callback the Annex-B sample.
        callback(sample)
    }

    func handleParameterSets(sample: CMSampleBuffer) throws -> CMSampleBuffer {
        // Get number of parameter sets.
        var sets: Int = 0
        let format = CMSampleBufferGetFormatDescription(sample)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                           parameterSetIndex: 0,
                                                           parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil,
                                                           parameterSetCountOut: &sets,
                                                           nalUnitHeaderLengthOut: nil)

        // Get actual parameter sets.
        var parameterSetPointers: [UnsafePointer<UInt8>] = .init()
        var parameterSetLengths: [Int] = .init()
        for parameterSetIndex in 0...sets-1 {
            var parameterSet: UnsafePointer<UInt8>?
            var parameterSize: Int = 0
            var naluSizeOut: Int32 = 0
            let formatError = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                                                 parameterSetIndex: parameterSetIndex,
                                                                                 parameterSetPointerOut: &parameterSet,
                                                                                 parameterSetSizeOut: &parameterSize,
                                                                                 parameterSetCountOut: nil,
                                                                                 nalUnitHeaderLengthOut: &naluSizeOut)
            guard formatError == .zero else { fatalError("Couldn't get description: \(formatError)") }
            guard naluSizeOut == startCodeLength else { fatalError("Unexpected start code length?") }
            parameterSetPointers.append(parameterSet!)
            parameterSetLengths.append(parameterSize)
        }

        // Compute total ANNEX B parameter set size.
        var totalLength = startCodeLength * sets
        totalLength += parameterSetLengths.reduce(0, { running, element in running + element })

        // Make a block buffer for PPS/SPS.
        var buffer: CMBlockBuffer?
        let blockError = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                            memoryBlock: nil,
                                                            blockLength: totalLength,
                                                            blockAllocator: nil,
                                                            customBlockSource: nil,
                                                            offsetToData: 0,
                                                            dataLength: totalLength,
                                                            flags: 0,
                                                            blockBufferOut: &buffer)
        guard blockError == .zero else { throw("Failed to create parameter set block") }

        let allocateError = CMBlockBufferAssureBlockMemory(buffer!)
        guard allocateError == .zero else { throw("Failed to allocate parameter set block") }

        var offset = 0
        for parameterSetIndex in 0...sets-1 {
            let startCodeError = CMBlockBufferReplaceDataBytes(with: startCode,
                                                               blockBuffer: buffer!,
                                                               offsetIntoDestination: offset,
                                                               dataLength: startCodeLength)
            guard startCodeError == .zero else { throw("Couldn't copy start code") }
            offset += startCodeLength
            let parameterDataError = CMBlockBufferReplaceDataBytes(with: parameterSetPointers[parameterSetIndex],
                                                                   blockBuffer: buffer!,
                                                                   offsetIntoDestination: offset,
                                                                   dataLength: parameterSetLengths[parameterSetIndex])
            guard parameterDataError == .zero else { throw("Couldn't copy parameter data") }
            offset += parameterSetLengths[parameterSetIndex]
        }

        // FIXME: Why does the above not work?
        try buffer!.withUnsafeMutableBytes { ptr in
            let firstAlterIndex = startCodeLength - 1
            ptr[firstAlterIndex] = 0x01
            let secondAlterIndex = startCodeLength * 2 + parameterSetLengths[0] - 1
            ptr[secondAlterIndex] = 0x01
        }

        // Return as a sample for easy callback.
        var time: CMSampleTimingInfo = try sample.sampleTimingInfo(at: 0)
        var parameterSample: CMSampleBuffer?
        let sampleError = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                    dataBuffer: buffer,
                                                    formatDescription: nil,
                                                    sampleCount: 1,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &time,
                                                    sampleSizeEntryCount: 1,
                                                    sampleSizeArray: &totalLength,
                                                    sampleBufferOut: &parameterSample)
        guard sampleError == .zero else { throw("Couldn't create parameter sample") }
        return parameterSample!
    }

    private func makeOrientationSEI(orientation: AVCaptureVideoOrientation, verticalMirror: Bool) -> CMSampleBuffer {
        var bytes: [UInt8] = [
            // Start Code.
            0x00, 0x00, 0x00, 0x01,

            // SEI NALU type,
            0x06,

            // Display orientation
            0x2f, 0x02,

            // Orientation payload.
            UInt8(orientation.rawValue),

            // Device position.
            verticalMirror ? 0x01 : 0x00,

            // Stop.
            0x80
        ]

        let memBlock = malloc(bytes.count)
        bytes.withUnsafeBytes { buffer in
            _ = memcpy(memBlock, buffer.baseAddress, bytes.count)
        }

        do {
            var block: CMBlockBuffer?
            let blockError = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                                memoryBlock: memBlock,
                                                                blockLength: bytes.count,
                                                                blockAllocator: nil,
                                                                customBlockSource: nil,
                                                                offsetToData: 0,
                                                                dataLength: bytes.count,
                                                                flags: 0,
                                                                blockBufferOut: &block)
            let sample: CMSampleBuffer = try .init(dataBuffer: block,
                                                   formatDescription: nil,
                                                   numSamples: 1,
                                                   sampleTimings: [],
                                                   sampleSizes: [bytes.count])
            return sample
        } catch {
            fatalError("?")
        }
    }
}

extension String: LocalizedError {
    public var message: String? { return self }
}
