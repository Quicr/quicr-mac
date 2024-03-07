import VideoToolbox
import CoreVideo
import UIKit
import AVFoundation
import os

// swiftlint:disable type_body_length

class VTEncoder {
    typealias EncodedCallback = (UnsafeRawBufferPointer, Bool) -> Void

    private static let logger = DecimusLogger(VTEncoder.self)

    var frameRate: Float64?
    private let callback: EncodedCallback
    private let config: VideoCodecConfig
    private let encoder: VTCompressionSession
    private let verticalMirror: Bool
    private let bufferAllocator: BufferAllocator
    private var sequenceNumber: UInt64 = 0
    private let emitStartCodes: Bool
    private let seiData: ApplicationSeiData

    private let startCode: [UInt8] = [ 0x00, 0x00, 0x00, 0x01 ]

    init(config: VideoCodecConfig, verticalMirror: Bool, callback: @escaping EncodedCallback, emitStartCodes: Bool = false) throws {
        self.verticalMirror = verticalMirror
        self.callback = callback
        self.config = config
        self.emitStartCodes = emitStartCodes
        self.bufferAllocator = .init(1*1024*1024, hdrSize: 512)
        let allocator: CFAllocator?
        #if targetEnvironment(macCatalyst)
        allocator = self.bufferAllocator.allocator().takeUnretainedValue()
        #else
        allocator = nil
        #endif

        var compressionSession: VTCompressionSession?
        let codec: CMVideoCodecType
        switch config.codec {
        case .h264:
            self.seiData = ApplicationH264SEIs()
            codec = kCMVideoCodecType_H264
        case .hevc:
            self.seiData = ApplicationHEVCSEIs()
            codec = kCMVideoCodecType_HEVC
        default:
            fatalError()
        }
        let created = VTCompressionSessionCreate(allocator: nil,
                                                 width: config.width,
                                                 height: config.height,
                                                 codecType: codec,
                                                 encoderSpecification: config.codec == .h264 ?
                                                    Self.makeEncoderSpecification() :
                                                    nil,
                                                 imageBufferAttributes: nil,
                                                 compressedDataAllocator: allocator,
                                                 outputCallback: nil,
                                                 refcon: nil,
                                                 compressionSessionOut: &compressionSession)
        guard created == .zero,
              let compressionSession = compressionSession else {
            throw "Compression Session was nil"
        }
        self.encoder = compressionSession

        try OSStatusError.checked("Set realtime") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_RealTime,
                                 value: kCFBooleanTrue)
        }

        try OSStatusError.checked("Set Profile Level") {
            return switch config.codec {
            case .h264:
                VTSessionSetProperty(encoder,
                                     key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
            case .hevc:
                VTSessionSetProperty(encoder,
                                     key: kVTCompressionPropertyKey_ProfileLevel,
                                     value: kVTProfileLevel_HEVC_Main_AutoLevel)
            default:
                1
            }
        }

        try OSStatusError.checked("Set allow frame reordering") {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        }

        let bitrateKey: CFString
        switch config.bitrateType {
        case .constant:
            bitrateKey = kVTCompressionPropertyKey_ConstantBitRate
        case .average:
            bitrateKey = kVTCompressionPropertyKey_AverageBitRate
        }

        try OSStatusError.checked("Set average bitrate: \(self.config.bitrate)") {
            VTSessionSetProperty(encoder,
                                 key: bitrateKey,
                                 value: config.bitrate as CFNumber)
        }

        let dataRateLimits: NSArray = [NSNumber(value: Double(self.config.bitrate) * self.config.limit1s / 8), NSNumber(value: 1)]
        try OSStatusError.checked("Set data limit: \(self.config.limit1s)x") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: dataRateLimits as CFArray)
        }

        try OSStatusError.checked("Set expected frame rate: \(self.config.fps)") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                 value: config.fps as CFNumber)
        }

        try OSStatusError.checked("Set max key frame interval: \(self.config.fps * 5)") {
            VTSessionSetProperty(encoder,
                                 key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: config.fps * 5 as CFNumber)
        }

        if config.codec == .hevc {
            try OSStatusError.checked("Color Primaries") {
                VTSessionSetProperty(encoder,
                                     key: kVTCompressionPropertyKey_ColorPrimaries,
                                     value: kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
            }

            try OSStatusError.checked("Transfer Function") {
                VTSessionSetProperty(encoder,
                                     key: kVTCompressionPropertyKey_TransferFunction,
                                     value: kCMFormatDescriptionTransferFunction_ITU_R_709_2)
            }

            try OSStatusError.checked("YCbCrMatrix") {
                VTSessionSetProperty(encoder,
                                     key: kVTCompressionPropertyKey_YCbCrMatrix,
                                     value: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
            }

            try OSStatusError.checked("Preserve Metadata") {
                VTSessionSetProperty(encoder,
                                     key: kVTCompressionPropertyKey_PreserveDynamicHDRMetadata,
                                     value: kCFBooleanTrue)
            }
        }

        try OSStatusError.checked("Prepare to encode frames") {
            VTCompressionSessionPrepareToEncodeFrames(encoder)
        }
    }

    deinit {
        // Sync flush all pending frames.
        let flushError = VTCompressionSessionCompleteFrames(encoder,
                                                            untilPresentationTimeStamp: .init())
        if flushError != .zero {
            Self.logger.error("Encoder failed to flush", alert: true)
        }

        VTCompressionSessionInvalidate(encoder)
    }

    func write(sample: CMSampleBuffer) throws {
        guard let imageBuffer = sample.imageBuffer else { throw "Missing image" }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        try OSStatusError.checked("Encode") {
            VTCompressionSessionEncodeFrame(self.encoder,
                                            imageBuffer: imageBuffer,
                                            presentationTimeStamp: timestamp,
                                            duration: .invalid,
                                            frameProperties: nil,
                                            infoFlagsOut: nil,
                                            outputHandler: self.encoded)
        }
    }

    func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        // Check the callback data.
        guard status == .zero else {
            Self.logger.error("Encode failure: \(status)")
            return
        }
        guard !flags.contains(.frameDropped) else {
            Self.logger.warning("Encoder dropped frame")
            return
        }
        guard let sample = sample else {
            Self.logger.error("Encoded sample was empty")
            return
        }

        let buffer: CMBlockBuffer
        #if !targetEnvironment(macCatalyst)
        let bufferSize = sample.dataBuffer!.dataLength
        bufferAllocator.iosDeallocBuffer(nil) // SAH - just resets pointers
        guard let bufferPtr = bufferAllocator.iosAllocBuffer(bufferSize) else {
            fatalError()
        }
        let rangedBufferPtr = UnsafeMutableRawBufferPointer(start: bufferPtr, count: bufferSize)
        do {
            buffer = try .init(buffer: rangedBufferPtr, deallocator: { _, _ in })
            try sample.dataBuffer!.copyDataBytes(to: rangedBufferPtr)
        } catch {
            Self.logger.error("Failed to copy data buffer: \(error.localizedDescription)")
            return
        }
        #else
        buffer  = sample.dataBuffer!
        #endif

        // Increment frame sequence number
        // Append Timestamp SEI to buffer
        self.sequenceNumber += 1
        let fps = UInt8(self.frameRate ?? Float64(self.config.fps))
        prependTimestampSEI(timestamp: sample.presentationTimeStamp,
                            sequenceNumber: self.sequenceNumber,
                            fps: fps,
                            bufferAllocator: bufferAllocator)

        // Append Orientation SEI to buffer
        #if !targetEnvironment(macCatalyst) && !os(tvOS)
        do {
//            try prependOrientationSEI(orientation: UIDevice.current.orientation.videoOrientation,
//                                      verticalMirror: verticalMirror,
//                                      bufferAllocator: bufferAllocator)
        } catch {
            Self.logger.error("Failed to prepend orientation SEI: \(error.localizedDescription)")
        }
        #endif

        // Prepend format data.
        let idr = sample.isIDR()
        if idr {
            // SPS + PPS.
            guard let parameterSets = try? handleParameterSets(sample: sample) else {
                Self.logger.error("Failed to handle parameter sets")
                return
            }

            // append SPS/PPS to beginning of buffer
            let totalSize = parameterSets.reduce(0) { current, set in
                current + set.count + self.startCode.count
            }
            guard let parameterDestinationAddress = bufferAllocator.allocateBufferHeader(totalSize) else {
                Self.logger.error("Couldn't allocate parameters buffer")
                return
            }
            let parameterDestination = UnsafeMutableRawBufferPointer(start: parameterDestinationAddress, count: totalSize)

            var offset = 0
            for set in parameterSets {
                // Copy either start code or UInt32 length.
                if self.emitStartCodes {
                    self.startCode.withUnsafeBytes {
                        parameterDestination.baseAddress!.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
                        offset += $0.count
                    }
                } else {
                    let length = UInt32(set.count).bigEndian
                    parameterDestination.storeBytes(of: length, toByteOffset: offset, as: UInt32.self)
                    offset += MemoryLayout<UInt32>.size
                }

                // Copy the parameter data.
                let dest = parameterDestination.baseAddress!.advanced(by: offset)
                let destBuffer = UnsafeMutableRawBufferPointer(start: dest, count: parameterDestination.count - offset)
                destBuffer.copyMemory(from: set)
                offset += set.count
            }
        }

        var offset = 0
        if self.emitStartCodes {
            // Replace buffer data with start code.
            while offset < buffer.dataLength - startCode.count {
                try! buffer.withUnsafeMutableBytes(atOffset: offset) {
                    // Get the length.
                    let naluLength = $0.loadUnaligned(as: UInt32.self).byteSwapped

                    // Replace with start code.
                    $0.copyBytes(from: self.startCode)

                    // Move to next NALU.
                    offset += startCode.count + Int(naluLength)
                }
            }
        }

        // Callback the full buffer.
        var fullEncodedRawPtr: UnsafeMutableRawPointer?
        var fullEncodedBufferLength: Int = 0
        bufferAllocator.retrieveFullBufferPointer(&fullEncodedRawPtr, len: &fullEncodedBufferLength)
        let fullEncodedBuffer = UnsafeRawBufferPointer(start: fullEncodedRawPtr, count: fullEncodedBufferLength)
        if self.emitStartCodes {
            assert(fullEncodedBuffer.starts(with: self.startCode))
        }
        callback(fullEncodedBuffer, idr)
    }

    /// Returns the parameter sets contained within the sample's format, if any.
    /// - Parameter sample The sample to extract parameter sets from.
    /// - Returns Array of buffer pointers referencing the data. This is only safe to use during the lifetime of sample.
    private func handleParameterSets(sample: CMSampleBuffer) throws -> [UnsafeRawBufferPointer] {
        // Get number of parameter sets.
        var sets: Int = 0
        try OSStatusError.checked("Get number of SPS/PPS") {
            switch self.config.codec {
            case .h264:
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sample.formatDescription!,
                                                                   parameterSetIndex: 0,
                                                                   parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &sets,
                                                                   nalUnitHeaderLengthOut: nil)
            case .hevc:
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(sample.formatDescription!,
                                                                   parameterSetIndex: 0,
                                                                   parameterSetPointerOut: nil,
                                                                   parameterSetSizeOut: nil,
                                                                   parameterSetCountOut: &sets,
                                                                   nalUnitHeaderLengthOut: nil)
            default:
                1
            }
        }

        // Get actual parameter sets.
        var parameterSetPointers: [UnsafeRawBufferPointer] = []
        for parameterSetIndex in 0...sets-1 {
            var parameterSet: UnsafePointer<UInt8>?
            var parameterSize: Int = 0
            var naluSizeOut: Int32 = 0
            try OSStatusError.checked("Get SPS/PPS data") {
                switch self.config.codec {
                case .h264:
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(sample.formatDescription!,
                                                                       parameterSetIndex: parameterSetIndex,
                                                                       parameterSetPointerOut: &parameterSet,
                                                                       parameterSetSizeOut: &parameterSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: &naluSizeOut)
                case .hevc:
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(sample.formatDescription!,
                                                                       parameterSetIndex: parameterSetIndex,
                                                                       parameterSetPointerOut: &parameterSet,
                                                                       parameterSetSizeOut: &parameterSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: &naluSizeOut)
                default:
                    1
                }
            }
            guard naluSizeOut == startCode.count else { throw "Unexpected start code length?" }
            parameterSetPointers.append(.init(start: parameterSet!, count: parameterSize))
        }
        return parameterSetPointers
    }

    private func prependTimestampSEI(timestamp: CMTime,
                                     sequenceNumber: UInt64,
                                     fps: UInt8,
                                     bufferAllocator: BufferAllocator) {
        let bytes = TimestampSei(timestamp: timestamp, sequenceNumber: sequenceNumber, fps: fps).getBytes(self.seiData, startCode: self.emitStartCodes)
        guard let timestampPtr = bufferAllocator.allocateBufferHeader(bytes.count) else {
            Self.logger.error("Couldn't allocate timestamp buffer")
            return
        }

        // Copy to buffer.
        bytes.copyBytes(to: .init(start: timestampPtr, count: bytes.count))
    }

    private func prependOrientationSEI(orientation: Double,
                                       verticalMirror: Bool,
                                       bufferAllocator: BufferAllocator) throws {
        let bytes = OrientationSei(orientation: orientation, verticalMirror: verticalMirror).getBytes(self.seiData, startCode: self.emitStartCodes)
        guard let orientationPtr = bufferAllocator.allocateBufferHeader(bytes.count) else { fatalError() }
        let orientationBufferPtr = UnsafeMutableRawBufferPointer(start: orientationPtr, count: bytes.count)
        bytes.copyBytes(to: orientationBufferPtr)
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

    /// Try to build an encoder specification dictionary.
    /// Attempts to retrieve the info for a HW encoder, but failing that, defaults to LowLatency.
    private static func makeEncoderSpecification() -> CFDictionary {
        var availableEncodersPtr: CFArray?
        VTCopyVideoEncoderList(nil, &availableEncodersPtr)

        let defaultSpec = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue
        ] as CFDictionary

        guard let availableEncoders = availableEncodersPtr as? [[CFString: Any]] else {
            return defaultSpec
        }

        guard let hwEncoder = availableEncoders.first(where: {
            guard let name = $0[kVTVideoEncoderList_CodecType] as? CMVideoCodecType else { return false }
            let isHardwareAccelerated = $0[kVTVideoEncoderList_IsHardwareAccelerated] != nil
            return name == kCMVideoCodecType_H264 && isHardwareAccelerated
        }) else {
            return defaultSpec
        }

        guard let hwEncoderID = hwEncoder[kVTVideoEncoderList_EncoderID] else {
            return defaultSpec
        }

        return [
            kVTVideoEncoderSpecification_EncoderID: hwEncoderID
        ] as CFDictionary
    }
}

extension String: LocalizedError {
    public var errorDescription: String? { return self }
}
