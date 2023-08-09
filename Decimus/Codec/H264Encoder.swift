import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation

class H264Encoder {
    typealias EncodedCallback = (UnsafeRawPointer, Int, Bool) -> Void
    private var encoder: VTCompressionSession?
    private let verticalMirror: Bool
    private let startCodeLength = 4
    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]
    private let callback: EncodedCallback
    private let bufferAllocator : BufferAllocator
    private let orientationSEI: [UInt8] = [
        // Length in little endian
        0x00, 0x00, 0x00, 0x19,
        // SEI NALU type,
        0x06,
        // Payload type - user_data_unregistered (5)
        0x05,
        // Payload size
        0x16,
        // UUID uuid_iso_lec_11578 (User Data Unregistered)
        0x2C, 0xA2, 0xDE, 0x09, 0xB5, 0x17, 0x47, 0xDB,
        0xBB, 0x55, 0xA4, 0xFE, 0x7F, 0xC2, 0xFC, 0x4E,
        // Application specific ID
        0x01, // Orientation/Position
        // Display orientation
        0x2F, 0x02,
        // Orientation payload.
        0x00,
        // Device position.
        0x00,
        // Stop. -- SAH - is this required?
        0x80
    ]
    
    private let timeSEI: [UInt8] = [
        // Start Code.
        0x00, 0x00, 0x00, 0x1C,
        // SEI NALU type,
        0x06,
        // Payload type - user_data_unregistered (5)
        0x05,
        // Payload size
        0x15,
        // UUID uuid_iso_lec_11578 (User Data Unregistered)
        0x2C, 0xA2, 0xDE, 0x09, 0xB5, 0x17, 0x47, 0xDB,
        0xBB, 0x55, 0xA4, 0xFE, 0x7F, 0xC2, 0xFC, 0x4E,
        // Application specific ID
        0x02, // Time ms
        // Time in ms.
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ]

    init(config: VideoCodecConfig, verticalMirror: Bool, callback: @escaping EncodedCallback) throws {
        self.verticalMirror = verticalMirror
        self.callback = callback

        let encoderSpecification = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary
        
        self.bufferAllocator = BufferAllocator(1*1024*1024, hdrSize: 256)
        
        try OSStatusError.checked("Creation") {
            VTCompressionSessionCreate(allocator: nil,
                                       width: config.width,
                                       height: config.height,
                                       codecType: kCMVideoCodecType_H264,
                                       encoderSpecification: encoderSpecification,
                                       imageBufferAttributes: nil,
                                       compressedDataAllocator: self.bufferAllocator.allocator().takeRetainedValue(),
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
        // Get pointer to encoded buffer
        // This is the key to be used to append headers, convert to stream headers, and
        // to get the total buffer to be written out as a frame.
        var length: Int = 0
        var encodedBufferPointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(sample.dataBuffer!,
                                    atOffset: 0,
                                    lengthAtOffsetOut: nil,
                                    totalLengthOut: &length,
                                    dataPointerOut: &encodedBufferPointer)
        // Process SEIs
        #if !targetEnvironment(macCatalyst)
        // Orientation SEI.
        var bytes = orientationSEI
        bytes[26] = UInt8(UIDevice.current.orientation.videoOrientation.rawValue)
        bytes[27] = verticalMirror ? 0x01 : 0x00

        bytes.withUnsafeBytes {
            let hdrPtr = bufferAllocator.allocateBufferHeader(bytes.count)
            if let hdrPtr = hdrPtr {
                hdrPtr.advanced(by: 0).copyMemory(from: $0.baseAddress!, byteCount: bytes.count)
            }
        }
        #endif
        
        #if USE_TIME_HEADERS
        var timeSEIBytes = timeSEI
        timeSEIBytes.withUnsafeMutableBytes {
            var currentTime = Int64(NSDate().timeIntervalSince1970 * 1000)
            memcpy($0.baseAddress! + 24, &currentTime, 8)
        }

        timeSEIBytes.withUnsafeBytes {
            let hdrPtr = bufferAllocator.allocateBufferHeader(timeSEIBytes.count)
            
            if let hdrPtr = hdrPtr {
                hdrPtr.advanced(by: 0).copyMemory(from: $0.baseAddress!, byteCount: timeSEIBytes.count)
            }
        }
        #endif
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
        guard let sampleAttachments = attachments[0] as? NSDictionary else { fatalError("Failed to get attachements") }
        let key = kCMSampleAttachmentKey_NotSync as NSString
        let foundAttachment = sampleAttachments[key] as? Bool?
        let idr = !(foundAttachment != nil && foundAttachment == true)
        if idr {
            // SPS + PPS.
            guard let format = sample.formatDescription else {
                print("Missing sample format")
                return
            }
            do {
                try handleParameterSets(encodedBufferPointer: encodedBufferPointer, format: format)
            } catch {
                print("Error prpending SPS/PPS to encoded buffer")
                return
            }
        }

        var fullEncodedRawPtr: UnsafeMutableRawPointer?
        var fullEncodedBufferLength: Int = 0
        bufferAllocator.retrieveFullBufferPointer(&fullEncodedRawPtr, len: &fullEncodedBufferLength)
        toAnnexB(bufferPtr: fullEncodedRawPtr, bufferLen: fullEncodedBufferLength)
        try callback(fullEncodedRawPtr!, fullEncodedBufferLength, idr)
    }

    func handleParameterSets(encodedBufferPointer: UnsafeMutablePointer<CChar>?,
                             format: CMFormatDescription) throws {
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
        let lengthSize = MemoryLayout<UInt32>.size

        // Get actual parameter sets.
        // Note: this is in reverse order so the SPS
        // will be added after the PPS and will be at the
        // beginning of the buffer.
        for parameterSetIndex in (0...sets-1).reversed() {
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
            let hdrPtr = bufferAllocator.allocateBufferHeader(lengthSize + parameterSize)
            if let hdrPtr = hdrPtr {
                var swapped = CFSwapInt32HostToBig(UInt32(parameterSize))
                hdrPtr.advanced(by: 0).copyMemory(from: &swapped, byteCount: lengthSize)
                hdrPtr.advanced(by: lengthSize).copyMemory(from: parameterSet!, byteCount: parameterSize)
            }
        }
    }
    
    func toAnnexB(bufferPtr: UnsafeMutableRawPointer?, bufferLen: Int ) {
        var startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]

        // Annex B the actual frame data.
        var offset = 0
        while offset < bufferLen - startCode.count {
            var naluLength: UInt32 = 0
            memcpy(&naluLength, bufferPtr! + offset, startCode.count)
            naluLength = CFSwapInt32BigToHost(naluLength)
            bufferPtr?.advanced(by: offset).copyMemory(from: &startCode, byteCount: startCode.count)
            // Carry on.
            offset += startCode.count + Int(naluLength)
        }
    }
}

extension String: LocalizedError {
    public var errorDescription: String? { return self }
}
