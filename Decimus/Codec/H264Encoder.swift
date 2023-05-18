import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation

class H264Encoder: SampleEncoder {
    internal var callback: EncodedSampleCallback?

    private var encoder: VTCompressionSession?
    private let verticalMirror: Bool

    private let startCodeLength = 4
    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]

    init(config: VideoCodecConfig, verticalMirror: Bool) {
        self.verticalMirror = verticalMirror

        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary

        let error = VTCompressionSessionCreate(allocator: nil,
                                               width: config.width,
                                               height: config.height,
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
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AverageBitRate, value: config.bitrate as CFNumber)
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: config.fps as CFNumber)
        VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 300 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(encoder!)
    }

    deinit {
        guard let session = encoder else { return }
        VTCompressionSessionInvalidate(session)
        self.encoder = nil
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
        guard let callback = callback else { fatalError("Callback not set for encoder") }
        guard status == .zero else { fatalError("Encode failure: \(status)")}
        guard let sample = sample else { return; }

        // Annex B time.
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
        guard let sampleAttachments = attachments[0] as? NSDictionary else { fatalError("Failed to get attachements") }

        let key = kCMSampleAttachmentKey_NotSync as NSString
        let foundAttachment = sampleAttachments[key] as? Bool?
        let idr = !(foundAttachment != nil && foundAttachment == true)

        if idr {
            // SPS + PPS.
            guard let parameterSets = try? handleParameterSets(sample: sample) else {
                print("Failed to handle parameter sets")
                return
            }
            callback(parameterSets)
        }

        #if !targetEnvironment(macCatalyst)
        // Orientation SEI.
        guard let orientationSei = try? makeOrientationSEI(orientation: UIDevice.current.orientation.videoOrientation,
                                                           verticalMirror: verticalMirror)
        else {
            print("Failed to make orientation SEI")
            return
        }
        callback(orientationSei)
        #endif

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
            guard accessError == .zero else { fatalError("Bad access: \(accessError)") }

            var naluLength: UInt32 = 0
            memcpy(&naluLength, data, startCodeLength)
            free(memory)
            naluLength = CFSwapInt32BigToHost(naluLength)

            // Replace with start code.
            CMBlockBufferReplaceDataBytes(with: startCode,
                                          blockBuffer: buffer,
                                          offsetIntoDestination: offset,
                                          dataLength: startCodeLength)

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
        let buffer = try makeBuffer(totalLength: totalLength)

        var offset = 0
        for parameterSetIndex in 0...sets-1 {
            let startCodeError = CMBlockBufferReplaceDataBytes(with: startCode,
                                                               blockBuffer: buffer,
                                                               offsetIntoDestination: offset,
                                                               dataLength: startCodeLength)
            guard startCodeError == .zero else { throw("Couldn't copy start code") }
            offset += startCodeLength
            let parameterDataError = CMBlockBufferReplaceDataBytes(with: parameterSetPointers[parameterSetIndex],
                                                                   blockBuffer: buffer,
                                                                   offsetIntoDestination: offset,
                                                                   dataLength: parameterSetLengths[parameterSetIndex])
            guard parameterDataError == .zero else { throw("Couldn't copy parameter data") }
            offset += parameterSetLengths[parameterSetIndex]
        }

        // Return as a sample for easy callback.
        return try makeParameterSampleBuffer(sample: sample, buffer: buffer, totalLength: totalLength)
    }

    private func makeOrientationSEI(orientation: AVCaptureVideoOrientation,
                                    verticalMirror: Bool) throws -> CMSampleBuffer {
        let bytes: [UInt8] = [
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

            guard blockError == .zero else { throw("Failed to create SEI memory block") }
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

    private func makeBuffer(totalLength: Int) throws -> CMBlockBuffer {
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

        return buffer!
    }

    private func makeParameterSampleBuffer(sample: CMSampleBuffer,
                                           buffer: CMBlockBuffer,
                                           totalLength: Int) throws -> CMSampleBuffer {
        var time: CMSampleTimingInfo = try sample.sampleTimingInfo(at: 0)
        var parameterSample: CMSampleBuffer?
        var length = totalLength
        let sampleError = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                    dataBuffer: buffer,
                                                    formatDescription: nil,
                                                    sampleCount: 1,
                                                    sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &time,
                                                    sampleSizeEntryCount: 1,
                                                    sampleSizeArray: &length,
                                                    sampleBufferOut: &parameterSample)
        guard sampleError == .zero else { throw("Couldn't create parameter sample") }
        return parameterSample!
    }
}

extension String: LocalizedError {
    public var message: String? { return self }
}
