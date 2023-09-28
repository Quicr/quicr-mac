import Foundation
import VideoToolbox
import AVFoundation
import CoreImage
import os

/// Provides hardware accelerated H264 decoding.
class H264Decoder {
    typealias DecodedFrameCallback = (CMSampleBuffer, AVCaptureVideoOrientation?, Bool) -> Void
    private static let logger = DecimusLogger(H264Decoder.self)

    // H264 constants.
    enum H264Types: UInt8 {
        case PFrame = 1
        case IDR = 5
        case SEI = 6
        case SPS = 7
        case PPS = 8
    }
    private let startCodeLength = 4

    // Members.
    private var currentFormat: CMFormatDescription?
    private let callback: DecodedFrameCallback
    private var orientation: AVCaptureVideoOrientation?
    private var verticalMirror: Bool = false

    /// Stored codec config. Can be updated.
    private var config: VideoCodecConfig

    init(config: VideoCodecConfig, callback: @escaping DecodedFrameCallback) {
        self.config = config
        self.callback = callback
    }

    /// Write a new frame to the decoder.
    func write(data: UnsafeRawBufferPointer, timestamp: UInt64) throws {
        // Get NALU type.
        var type = H264Types(rawValue: data[startCodeLength] & 0x1F)

        // If we don't know the format yet, skip anything except SPS.
        guard self.currentFormat != nil || type == .SPS else { return }

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
        for index in startCodeIndices.indices {
            // Get NALU attributes.
            let thisNaluOffset = startCodeIndices[index]
            var naluTotalLength = data.count - index
            if startCodeIndices.count < index + 1 {
                naluTotalLength = startCodeIndices[index + 1] - thisNaluOffset
            }
            let naluPtr: UnsafeMutableRawPointer = .init(mutating: data.baseAddress!.advanced(by: thisNaluOffset))

            // What type is this NALU?
            type = H264Types(rawValue: data[thisNaluOffset + startCodeLength] & 0x1F)
            guard type == .PFrame || type == .IDR || type == .SEI else {
                Self.logger.info("Unhandled NALU type: \(String(describing: type))")
                continue
            }

            // Change start code to length
            var naluDataLength = UInt32(naluTotalLength - startCodeLength).bigEndian
            memcpy(naluPtr, &naluDataLength, startCodeLength)

            // Parse any SEIs and move on.
            if type == .SEI {
                do {
                    try parseSEI(pointer: naluPtr)
                } catch {
                    // TODO: Surface this error.
                    Self.logger.error("\(error.localizedDescription)")
                }
                continue
            }

            // Construct a block buffer from this NALU.
            var blockBuffer: CMBlockBuffer?
            var error = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                           memoryBlock: naluPtr,
                                                           blockLength: naluTotalLength,
                                                           blockAllocator: kCFAllocatorNull,
                                                           customBlockSource: nil,
                                                           offsetToData: 0,
                                                           dataLength: naluTotalLength,
                                                           flags: 0,
                                                           blockBufferOut: &blockBuffer)

            guard error == .zero else {
                throw OSStatusError(error: error, message: "CMBlockBufferCreateWithMemoryBlock")
            }

            // CMTime presentation.
            let time = CMTimeMake(value: Int64(timestamp), timescale: Int32(config.fps))
            var timeInfo = CMSampleTimingInfo(duration: CMTimeMakeWithSeconds(1.0, preferredTimescale: Int32(config.fps)),
                                              presentationTimeStamp: time,
                                              decodeTimeStamp: .invalid)

            // Create sample buffer.
            var sampleSize = naluTotalLength
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

            guard let sampleBuffer = sampleBuffer else {
                Self.logger.error("Failed to create sample buffer")
                return
            }

            callback(sampleBuffer, orientation, verticalMirror)
        }
    }

    /// Extracts parameter sets from the given pointer, if any.
    private func checkParameterSets(data: UnsafeRawBufferPointer, length: Int) throws -> (Int, CMFormatDescription?) {

        // Get current frame type.
        let type = H264Types(rawValue: data[startCodeLength] & 0x1F)

        // Is this SPS?
        var ppsStartCodeIndex: Int = 0
        var spsLength: Int = 0
        if type == .SPS {
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
        let secondType = H264Types(rawValue: data[ppsStartCodeIndex + startCodeLength] & 0x1F)
        var ppsLength: Int = 0
        guard secondType == .PPS else { return (idrStartCodeIndex, self.currentFormat) }

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

        if self.currentFormat == nil {
            self.currentFormat = format
        }

        // Return new pointer index.
        return (idrStartCodeIndex, format)
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

    private func parseSEI(pointer: UnsafeMutableRawPointer) throws {
        let typed: UnsafeMutablePointer<UInt8> = pointer.assumingMemoryBound(to: UInt8.self)
        let type = H264Types(rawValue: typed[4])

        guard type == .SEI else { throw "\(String(describing: type)) is not an SEI" }

        let seiType = typed[5]
        switch seiType {
        case 0x2f:
            // Video orientation.
            assert(typed[6] == 2)
            orientation = .init(rawValue: .init(typed[7]))
            verticalMirror = typed[8] == 1
        default:
                Self.logger.info("Unhandled SEI App type: \(seiType)")
        }
    }
}
