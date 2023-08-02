import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation

class H264Encoder {
    typealias EncodedCallback = (UnsafeRawBufferPointer, Bool) -> Void
    private var encoder: VTCompressionSession?
    private let verticalMirror: Bool
    private let startCodeLength = 4
    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]
    private let callback: EncodedCallback
    private let orientationSei: [UInt8] = [
        // Start Code.
        0x00, 0x00, 0x00, 0x01,
        // SEI NALU type,
        0x06,
        // Display orientation
        0x2f, 0x02,
        // Orientation payload.
        0x00,
        // Device position.
        0x00,
        // Stop.
        0x80
    ]

    init(config: VideoCodecConfig, verticalMirror: Bool, callback: @escaping EncodedCallback) throws {
        self.verticalMirror = verticalMirror
        self.callback = callback

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
        guard status == .zero else { fatalError("Encode failure: \(status)")}
        guard let sample = sample else { return; }

        // Annex B time.
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
        guard let sampleAttachments = attachments[0] as? NSDictionary else { fatalError("Failed to get attachements") }

        let key = kCMSampleAttachmentKey_NotSync as NSString
        let foundAttachment = sampleAttachments[key] as? Bool?
        let idr = !(foundAttachment != nil && foundAttachment == true)

        var parameterSets: UnsafeRawBufferPointer?
        if idr {
            // SPS + PPS.
            guard let format = sample.formatDescription else {
                print("Missing sample format")
                return
            }
            do {
                parameterSets = try handleParameterSets(format: format)
            } catch {
                fatalError("Handle parameter sets")
            }
        }

        var requiredLength = sample.totalSampleSize
        if let sets = parameterSets {
            requiredLength += sets.count
        }
        #if !targetEnvironment(macCatalyst)
        requiredLength += orientationSei.count
        #endif

        var frameData: UnsafeMutableRawBufferPointer = .allocate(byteCount: requiredLength, alignment: MemoryLayout<UInt8>.alignment)
        var frameDataOffset = 0

        // Copy in SPS/PPS.
        if let sets = parameterSets {
            frameData.copyMemory(from: sets)
            sets.deallocate()
            frameDataOffset += sets.count
        }

        #if !targetEnvironment(macCatalyst)
        // Orientation SEI.
        var bytes = orientationSei
        bytes[7] = UInt8(UIDevice.current.orientation.videoOrientation.rawValue)
        bytes[8] = verticalMirror ? 0x01 : 0x00
        bytes.copyBytes(to: .init(start: frameData.baseAddress! + frameDataOffset,
                                  count: requiredLength - frameDataOffset))
        frameDataOffset += orientationSei.count
        #endif

        // Copy the frame data.
        let offseted: UnsafeMutableRawBufferPointer = .init(start: frameData.baseAddress! + frameDataOffset,
                                                            count: frameData.count - frameDataOffset)
        do {
            try sample.toAnnexB()
            try sample.dataBuffer!.copyDataBytes(to: offseted)
        } catch {
            print("Failed to annex B & copy actual frame")
            return
        }

        // Callback the Annex-B sample.
        callback(.init(frameData), idr)
    }

    func handleParameterSets(format: CMFormatDescription) throws -> UnsafeRawBufferPointer {
        // Get number of parameter sets.
        var sets: Int = 0
        try OSStatusError.checked("Get number of SPS/PPS") {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
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
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format,
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
        let spspps: UnsafeMutableRawBufferPointer = .allocate(byteCount: totalLength,
                                                              alignment: MemoryLayout<UInt8>.alignment)
        var offset = 0
        var mutableStartCode = startCode
        for parameterSetIndex in 0...sets-1 {
            spspps.baseAddress?.advanced(by: offset).copyMemory(from: &mutableStartCode, byteCount: startCodeLength)
            offset += startCodeLength
            spspps.baseAddress?.advanced(by: offset).copyMemory(from: parameterSetPointers[parameterSetIndex],
                                                                byteCount: parameterSetLengths[parameterSetIndex])
            offset += parameterSetLengths[parameterSetIndex]
        }
        return .init(spspps)
    }
}

extension String: LocalizedError {
    public var errorDescription: String? { return self }
}

extension CMSampleBuffer {
    func toAnnexB() throws {
        let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]
        guard let buffer = self.dataBuffer else {
            throw "No data buffer"
        }
        let memory: UnsafeMutableRawBufferPointer = .allocate(byteCount: startCode.count,
                                                              alignment: MemoryLayout<UInt8>.alignment)
        defer { memory.deallocate() }

        // Annex B the actual frame data.
        var offset = 0
        while offset < buffer.dataLength - startCode.count {
            var data: UnsafeMutablePointer<CChar>?
            try OSStatusError.checked("CMBlockBufferAccessDataBytes") {
                CMBlockBufferAccessDataBytes(buffer,
                                             atOffset: offset,
                                             length: memory.count,
                                             temporaryBlock: memory.baseAddress!,
                                             returnedPointerOut: &data)
            }

            var naluLength: UInt32 = 0
            memcpy(&naluLength, data, startCode.count)
            naluLength = CFSwapInt32BigToHost(naluLength)

            // Replace with start code.
            try OSStatusError.checked("CMBlockBufferReplaceDataBytes") {
                CMBlockBufferReplaceDataBytes(with: startCode,
                                              blockBuffer: buffer,
                                              offsetIntoDestination: offset,
                                              dataLength: startCode.count)
            }

            // Carry on.
            offset += startCode.count + Int(naluLength)
        }
    }
}
