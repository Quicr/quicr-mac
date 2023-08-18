import Foundation
import VideoToolbox
import AVFoundation
import CoreImage
import os

/// Provides hardware accelerated H264 decoding.
class H264Decoder: SampleDecoder {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: H264Decoder.self)
    )

    // H264 constants.
    private let spsType: UInt8 = 7
    private let ppsType: UInt8 = 8
    private let startCodeLength = 4
    private let pFrame = 1
    private let idr = 5
    private let sei = 6
    private let userDataUnregisteredPayload = 5
    private let seiAppIDOrientation = 1
    private let seiAppIDTime = 2

    // Members.
    private var currentFormat: CMFormatDescription?
    private var session: VTDecompressionSession?
    internal var callback: DecodedCallback?
    private var orientation: AVCaptureVideoOrientation?
    private var verticalMirror: Bool = false

    /// Stored codec config. Can be updated.
    private var config: VideoCodecConfig

    init(config: VideoCodecConfig) {
        self.config = config
    }

    deinit {
        guard let session = self.session else { return }
        let flush = VTDecompressionSessionWaitForAsynchronousFrames(session)
        if flush != .zero {
            Self.logger.info("H264Decoder failed to flush frames")
        }
        VTDecompressionSessionInvalidate(session)
        // TODO: Remove this trace
        Self.logger.trace("deinit")
    }

    /// Write a new frame to the decoder.
    func write(data: UnsafeRawBufferPointer, timestamp: UInt32) throws {
        // Get NALU type.
        var type = data[startCodeLength] & 0x1F

        // If we don't know the format yet, skip anything except SPS.
        guard self.currentFormat != nil || type == spsType else { return }

        // Extract SPS/PPS if available.
        let paramOutput = try checkParameterSets(data: data, length: data.count)
        let offset = paramOutput.0
        let newFormat = paramOutput.1

        // There might not be any more data left.
        guard offset < data.count else { return }

        // Get indexes for all start codes.
        var startCodeIndices: [Int] = []
        for byte in offset...data.count - startCodeLength where isAtStartCode(pointer: data, startIndex: byte) {
            startCodeIndices.append(byte)
        }
        // Handle all remaining NALUs.
        for startCodeIndex in startCodeIndices.indices {
            // Get NALU attributes.
            let thisNaluOffset = startCodeIndices[startCodeIndex]
            var thisNaluLength = data.count - thisNaluOffset
            if startCodeIndex < startCodeIndices.count - 1 {
                thisNaluLength = startCodeIndices[startCodeIndex + 1] - thisNaluOffset
            }
            let naluPtr: UnsafeMutableRawPointer = .init(mutating: data.baseAddress!.advanced(by: thisNaluOffset))

            // What type is this NALU?
            type = data[thisNaluOffset + startCodeLength] & 0x1F
            guard type == pFrame || type == idr || type == sei else { Self.logger.info("Unhandled NALU type: \(type)"); continue }

            // Change start code to length
            var naluDataLength = UInt32(thisNaluLength - startCodeLength).bigEndian
            memcpy(naluPtr, &naluDataLength, startCodeLength)

            // Parse any SEIs and move on.
            if type == sei {
                do {
                    try parseSEI(
                        pointer: naluPtr.advanced(by: Int(startCodeLength)),
                        nalLength: UInt32(thisNaluLength) - UInt32(startCodeLength))
                } catch {
                    // TODO: Surface this error.
                    Self.logger.info("\(error.localizedDescription)")
                }
                continue
            }

            // Construct a block buffer from this NALU.
            var blockBuffer: CMBlockBuffer?
            var error = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                           memoryBlock: naluPtr,
                                                           blockLength: thisNaluLength,
                                                           blockAllocator: kCFAllocatorNull,
                                                           customBlockSource: nil,
                                                           offsetToData: 0,
                                                           dataLength: thisNaluLength,
                                                           flags: 0,
                                                           blockBufferOut: &blockBuffer)
            guard error == .zero else {
                throw OSStatusError(error: error, message: "CMBlockBufferCreateWithMemoryBlock")
            }

            // CMTime presentation.
            let time = CMTimeMake(value: Int64(timestamp), timescale: 1000)
            var timeInfo = CMSampleTimingInfo(duration: .invalid,
                                              presentationTimeStamp: time,
                                              decodeTimeStamp: .invalid)

            // Create sample buffer.
            var sampleSize = thisNaluLength
            var sampleBuffer: CMSampleBuffer?
            error = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                         dataBuffer: blockBuffer,
                                         dataReady: true,
                                         makeDataReadyCallback: nil,
                                         refcon: nil,
                                         formatDescription: newFormat,
                                         sampleCount: 1,
                                         sampleTimingEntryCount: 1,
                                         sampleTimingArray: &timeInfo,
                                         sampleSizeEntryCount: 1,
                                         sampleSizeArray: &sampleSize,
                                         sampleBufferOut: &sampleBuffer)
            guard error == .zero else {
                throw OSStatusError(error: error, message: "CMSampleBufferCreate")
            }

            // Set to display immediately
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self),
                                 unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self))

            // Pass sample to decoder.
            var outputFlags: VTDecodeInfoFlags = .init()
            let decodeError = VTDecompressionSessionDecodeFrame(session!,
                                                                sampleBuffer: sampleBuffer!,
                                                                flags: .init(),
                                                                infoFlagsOut: &outputFlags,
                                                                outputHandler: self.frameCallback)

            switch decodeError {
            case kVTFormatDescriptionChangeNotSupportedErr:
                // We need to recreate the decoder because of a format change.
                Self.logger.info("Recreating due to format change")
                session = try makeDecoder(format: newFormat!)
                try write(data: data, timestamp: timestamp)
            case .zero:
                break
            default:
                throw OSStatusError(error: error, message: "Failed to decode frame")
            }
        }
    }

    /// Extracts parameter sets from the given pointer, if any.
    private func checkParameterSets(data: UnsafeRawBufferPointer, length: Int) throws -> (Int, CMFormatDescription?) {

        // Get current frame type.
        let type = data[startCodeLength] & 0x1F

        // Is this SPS?
        var ppsStartCodeIndex: Int = 0
        var spsLength: Int = 0
        if type == spsType {
            for byte in startCodeLength...length - 1 where isAtStartCode(pointer: data, startIndex: byte) {
                // Find the next start code.
                ppsStartCodeIndex = byte
                spsLength = ppsStartCodeIndex - startCodeLength
                break
            }

            guard ppsStartCodeIndex != 0 else {
                throw "Expected to find PPS start code after SPS"
            }
        }

        // Check for PPS.
        var idrStartCodeIndex: Int = 0
        let secondType = data[ppsStartCodeIndex + startCodeLength] & 0x1F
        var ppsLength: Int = 0
        guard secondType == ppsType else { return (idrStartCodeIndex, self.currentFormat) }

        // Get PPS.
        for byte in ppsStartCodeIndex + startCodeLength...length + startCodeLength where
            isAtStartCode(pointer: data, startIndex: byte) {
                idrStartCodeIndex = byte
                ppsLength = idrStartCodeIndex - spsLength - (startCodeLength * 2)
                break
        }

        if idrStartCodeIndex == 0 {
            // We made it to the end, PPS must run to end.
            ppsLength = length - ppsStartCodeIndex - startCodeLength
            idrStartCodeIndex = length
        }

        // Collate SPS & PPS.
        let pointerSPS = data.baseAddress!
            .advanced(by: startCodeLength)
            .assumingMemoryBound(to: UInt8.self)
        let pointerPPS = data.baseAddress!
            .advanced(by: ppsStartCodeIndex + startCodeLength)
            .assumingMemoryBound(to: UInt8.self)

        let parameterSetsData = [pointerSPS, pointerPPS]
        let parameterSetsSizes = [spsLength, ppsLength]

        // Create format from parameter sets.
        var format: CMFormatDescription?
        let error = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                                                                        parameterSetCount: 2,
                                                                        parameterSetPointers: parameterSetsData,
                                                                        parameterSetSizes: parameterSetsSizes,
                                                                        nalUnitHeaderLength: Int32(startCodeLength),
                                                                        formatDescriptionOut: &format)
        guard error == .zero else {
            throw OSStatusError(error: error, message: "CMVideoFormatDescriptionCreateFromH264ParameterSets failed")
        }

        // Create the decoder with the given format.
        if session == nil {
            session = try makeDecoder(format: format!)
        }

        // Return new pointer index.
        return (idrStartCodeIndex, format)
    }

    /// Makes a new decoder for the given format.
    private func makeDecoder(format: CMFormatDescription) throws -> VTDecompressionSession {
        // Output format properties.
        var outputFormat: [String: Any] = [:]
        if CVIsCompressedPixelFormatAvailable(kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange) {
            outputFormat[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
        }

        // Create the session.
        var session: VTDecompressionSession?
        let error = VTDecompressionSessionCreate(allocator: nil,
                                                 formatDescription: format,
                                                 decoderSpecification: nil,
                                                 imageBufferAttributes: outputFormat as CFDictionary,
                                                 outputCallback: nil,
                                                 decompressionSessionOut: &session)
        guard error == .zero else {
            throw OSStatusError(error: error, message: "Failed to create VTDecompressionSession")
        }
        self.currentFormat = format

        // Configure for realtime.
        VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        return session!
    }

    func frameCallback(status: OSStatus,
                       flags: VTDecodeInfoFlags,
                       image: CVImageBuffer?,
                       presentation: CMTime,
                       duration: CMTime) {
        guard let callback = callback else {
            // TODO: Surface this error.
            fatalError("Callback not set for decoder")
        }

        // Check status code.
        guard status == .zero else { Self.logger.info("Bad decode: \(status)"); return }

        // Fire callback with the decoded image.
        guard let image = image else { Self.logger.info("Missing image"); return }
        do {
            let created: CMVideoFormatDescription = try .init(imageBuffer: image)
            let sample: CMSampleBuffer = try .init(imageBuffer: image,
                                                   formatDescription: created,
                                                   sampleTiming: .init(duration: duration,
                                                                       presentationTimeStamp: presentation,
                                                                       decodeTimeStamp: .invalid))
            callback(sample, presentation.value, orientation, verticalMirror)
        } catch {
            Self.logger.info("Couldn't create CMSampleBuffer: \(error)")
        }
    }

    /// Determines if the current pointer is pointing to the start of a NALU start code.
    func isAtStartCode(pointer: UnsafeRawBufferPointer, startIndex: Int) -> Bool {
        guard startIndex <= pointer.count - startCodeLength else { return false }
        return
            pointer[startIndex] == 0x00 &&
            pointer[startIndex + 1] == 0x00 &&
            pointer[startIndex + 2] == 0x00 &&
            pointer[startIndex + 3] == 0x01
    }

    private func parseSEI(pointer: UnsafeMutableRawPointer, nalLength: UInt32) throws {
        let typed: UnsafeMutablePointer<UInt8> = pointer.assumingMemoryBound(to: UInt8.self)
        guard typed[0] == sei else { throw "This is not an SEI" }
        let payloadType = typed[1]
        if payloadType == userDataUnregisteredPayload {
            guard nalLength > 19 else { Self.logger.info("User Unregistered SEI length too small"); return }
            let seiAppType = typed[19]
            switch seiAppType {
            case 0x01: // Orientation
                guard nalLength == 25 else { Self.logger.info("Orientation SEI length too small"); return }
                // Video orientation.
                assert(typed[21] == 2)
                orientation = .init(rawValue: .init(typed[22]))
                verticalMirror = typed[23] == 1
            case 0x02: // Time
                guard nalLength == 28 else { Self.logger.info("Time SEI length too small"); return}
                // process time here
                var messageTime: Int64 = 0
                memcpy(&messageTime, pointer+20, 8)
            default:
                Self.logger.info("Unhandled SEI App type: \(seiAppType)")
            }
        } else {
            Self.logger.info("Unhandled SEI payload type: \(payloadType)")
        }
    }
}
