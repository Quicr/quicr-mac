import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation

class H264Encoder: Encoder {
    internal var callback: EncodedCallback?

    private var encoder: VTCompressionSession?
    private let verticalMirror: Bool

    private let startCodeLength = 4
    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]

    init(config: VideoCodecConfig, verticalMirror: Bool) throws {
        self.verticalMirror = verticalMirror

        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary

        try OSStatusError.checked("Creation") {
            VTCompressionSessionCreate(allocator: nil,
                                       width: config.width,
                                       height: config.height,
                                       codecType: kCMVideoCodecType_H264,
                                       encoderSpecification: encoderSpecification,
                                       imageBufferAttributes: nil,
                                       compressedDataAllocator: nil,
                                       outputCallback: nil,
                                       refcon: nil,
                                       compressionSessionOut: &encoder)
        }

        try OSStatusError.checked("Set realtime") {
            VTSessionSetProperty(encoder!,
                                 key: kVTCompressionPropertyKey_RealTime,
                                 value: kCFBooleanTrue)
        }

        try OSStatusError.checked("Set Constrained High Autolevel") {
            VTSessionSetProperty(encoder!,
                                 key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        }

        try OSStatusError.checked("Set allow frame reordering") {
            VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        }

        try OSStatusError.checked("Set average bitrate: \(config.bitrate)") {
            VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_AverageBitRate, value: config.bitrate as CFNumber)
        }

        try OSStatusError.checked("Set expected frame rate: \(config.fps)") {
            VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: config.fps as CFNumber)
        }

        try OSStatusError.checked("Set max key frame interval: \(config.fps * 5)") {
            VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: config.fps * 5 as CFNumber)
        }

        try OSStatusError.checked("Prepare to encode frames") {
            VTCompressionSessionPrepareToEncodeFrames(encoder!)
        }
    }

    deinit {
        guard let session = encoder else { return }

        // Sync flush all pending frames.
        let flushError = VTCompressionSessionCompleteFrames(session,
                                                            untilPresentationTimeStamp: .init())
        if flushError != .zero {
            // TODO: Report this error.
            print("H264 Encoder failed to flush")
        }

        VTCompressionSessionInvalidate(session)
    }

    func write(sample: CMSampleBuffer) throws {
        guard let compressionSession = encoder else { return }
        guard let imageBuffer = sample.imageBuffer else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        try OSStatusError.checked("Encode") {
            VTCompressionSessionEncodeFrame(compressionSession,
                                                        imageBuffer: imageBuffer,
                                                        presentationTimeStamp: timestamp,
                                                        duration: .invalid,
                                                        frameProperties: nil,
                                                        infoFlagsOut: nil,
                                                        outputHandler: self.encoded)
        }
    }

    func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        // TODO: Report these errors.
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
            callback(parameterSets, idr)
        }

        #if !targetEnvironment(macCatalyst)
        // Orientation SEI.
        guard let orientationSei = try? makeOrientationSEI(orientation: UIDevice.current.orientation.videoOrientation,
                                                           verticalMirror: verticalMirror)
        else {
            print("Failed to make orientation SEI")
            return
        }
        try? callback(orientationSei.dataBuffer!.dataBytes(), idr)
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
        try? callback(sample.dataBuffer!.dataBytes(), idr)
    }

    func handleParameterSets(sample: CMSampleBuffer) throws -> Data {
        // Get number of parameter sets.
        var sets: Int = 0
        let format = CMSampleBufferGetFormatDescription(sample)
        try OSStatusError.checked("Get number of SPS/PPS") {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                               parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &sets,
                                                               nalUnitHeaderLengthOut: nil)
        }

        // Get actual parameter sets.
        var parameterSetPointers: [UnsafePointer<UInt8>] = .init()
        var parameterSetLengths: [Int] = .init()
        for parameterSetIndex in 0...sets-1 {
            var parameterSet: UnsafePointer<UInt8>?
            var parameterSize: Int = 0
            var naluSizeOut: Int32 = 0
            try OSStatusError.checked("Get SPS/PPS data") {
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format!,
                                                                   parameterSetIndex: parameterSetIndex,
                                                                   parameterSetPointerOut: &parameterSet,
                                                                   parameterSetSizeOut: &parameterSize,
                                                                   parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: &naluSizeOut)
            }
            guard naluSizeOut == startCodeLength else { throw "Unexpected start code length?" }
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
            try OSStatusError.checked("Set SPS/PPS start code") {
                CMBlockBufferReplaceDataBytes(with: startCode,
                                              blockBuffer: buffer,
                                              offsetIntoDestination: offset,
                                              dataLength: startCodeLength)
            }
            offset += startCodeLength
            try OSStatusError.checked("Copy SPS/PPS data") {
                CMBlockBufferReplaceDataBytes(with: parameterSetPointers[parameterSetIndex],
                                              blockBuffer: buffer,
                                              offsetIntoDestination: offset,
                                              dataLength: parameterSetLengths[parameterSetIndex])
            }
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

        var block: CMBlockBuffer?
        try OSStatusError.checked("Create SEI memory block") {
            CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                               memoryBlock: memBlock,
                                               blockLength: bytes.count,
                                               blockAllocator: nil,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: bytes.count,
                                               flags: 0,
                                               blockBufferOut: &block)
        }
        return try .init(dataBuffer: block,
                         formatDescription: nil,
                         numSamples: 1,
                         sampleTimings: [],
                         sampleSizes: [bytes.count])
    }

    private func makeBuffer(totalLength: Int) throws -> CMBlockBuffer {
        var buffer: CMBlockBuffer?
        try OSStatusError.checked("Create memory block") {
            CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                               memoryBlock: nil,
                                               blockLength: totalLength,
                                               blockAllocator: nil,
                                               customBlockSource: nil,
                                               offsetToData: 0,
                                               dataLength: totalLength,
                                               flags: 0,
                                               blockBufferOut: &buffer)
        }
        try OSStatusError.checked("Assure memory block") {
            CMBlockBufferAssureBlockMemory(buffer!)
        }
        return buffer!
    }

    private func makeParameterSampleBuffer(sample: CMSampleBuffer,
                                           buffer: CMBlockBuffer,
                                           totalLength: Int) throws -> Data {
        var time: CMSampleTimingInfo = try sample.sampleTimingInfo(at: 0)
        var parameterSample: CMSampleBuffer?
        var length = totalLength
        try OSStatusError.checked("Create SPS/PPS Buffer") {
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                      dataBuffer: buffer,
                                      formatDescription: nil,
                                      sampleCount: 1,
                                      sampleTimingEntryCount: 1,
                                      sampleTimingArray: &time,
                                      sampleSizeEntryCount: 1,
                                      sampleSizeArray: &length,
                                      sampleBufferOut: &parameterSample)
        }
        return try parameterSample!.dataBuffer!.dataBytes()
    }
}

extension String: LocalizedError {
    public var errorDescription: String? { return self }
}
