import Foundation
import VideoToolbox

/// Decoder callback of image and timestamp.
typealias DecodedImageCallback = (CGImage, CMTimeValue) -> Void

/// Provides hardware accelerated H264 decoding.
class H264Decoder: Decoder {

    // H264 constants.
    private let spsType: UInt8 = 7
    private let ppsType: UInt8 = 8
    private let startCodeLength = 4
    private let pFrame = 1
    private let idr = 5

    // Members.
    private var currentFormat: CMFormatDescription?
    private var session: VTDecompressionSession?
    private let callback: DecodedImageCallback

    /// Initialize a new decoder.
    init(callback: @escaping DecodedImageCallback) {
        self.callback = callback
    }

    /// Write a new frame to the decoder.
    func write(data: UnsafePointer<UInt8>, length: Int, timestamp: UInt32) {
        // Get NALU type.
        var type = data[startCodeLength] & 0x1F

        // If we don't know the format yet, skip anything except SPS.
        guard self.currentFormat != nil || type == spsType else { return }

        // Extract SPS/PPS if available.
        let offset = checkParameterSets(data: data, length: length)

        // There might not be any more data left.
        guard offset < length else { return }

        // Normal frame handling.
        type = data[offset + startCodeLength] & 0x1F
        guard type == pFrame || type == idr else { print("Unhandled NALU type: \(type)"); return }

        // Change start code to length
        let ptr: UnsafeMutableRawPointer = .init(mutating: data)
        let picDataLength = UInt32(length - offset - startCodeLength).bigEndian
        var embedLength = picDataLength
        memcpy(ptr, &embedLength, startCodeLength)

        // Construct the block buffer from the rest of the frame.
        var buffer: CMBlockBuffer?
        var error = CMBlockBufferCreateWithMemoryBlock(allocator: nil,
                                                       memoryBlock: ptr,
                                                       blockLength: length - offset,
                                                       blockAllocator: kCFAllocatorNull,
                                                       customBlockSource: nil,
                                                       offsetToData: 0,
                                                       dataLength: length - offset,
                                                       flags: 0,
                                                       blockBufferOut: &buffer)
        guard error == .zero else { fatalError("CMBlockBufferCreateWithMemoryBlock failed: \(error)") }

        // CMTime presentation.
        let time = CMTimeMake(value: Int64(timestamp), timescale: 1000)
        var timeInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)

        // Create sample buffer.
        var sampleSize = length - offset
        var sampleBuffer: CMSampleBuffer?
        error = CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                                     dataBuffer: buffer,
                                     dataReady: true,
                                     makeDataReadyCallback: nil,
                                     refcon: nil,
                                     formatDescription: self.currentFormat,
                                     sampleCount: 1,
                                     sampleTimingEntryCount: 1,
                                     sampleTimingArray: &timeInfo,
                                     sampleSizeEntryCount: 1,
                                     sampleSizeArray: &sampleSize,
                                     sampleBufferOut: &sampleBuffer)
        guard error == .zero else { fatalError("CMSampleBufferCreate failed: \(error)") }

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
        guard decodeError == .zero else { fatalError("Failed to decode frame: \(error)") }
    }

    /// Extracts parameter sets from the given pointer, if any.
    private func checkParameterSets(data: UnsafePointer<UInt8>, length: Int) -> Int {

        // Get current frame type.
        let type = data[4] & 0x1F

        // Is this SPS?
        var ppsStartCodeIndex: Int = 0
        var spsLength: Int = 0
        if type == spsType {
            for byte in 4...length - 1 where isAtStartCode(pointer: data, startIndex: byte) {
                // Find the next start code.
                ppsStartCodeIndex = byte
                spsLength = ppsStartCodeIndex - 4
                break
            }

            guard ppsStartCodeIndex != 0 else { fatalError("Expected to find PPS start code after SPS") }
        }

        // Check for PPS.
        var idrStartCodeIndex: Int = 0
        let secondType = data[ppsStartCodeIndex + 4] & 0x1F
        var ppsLength: Int = 0
        guard secondType == ppsType else { return idrStartCodeIndex }

        // Get PPS.
        for byte in (ppsStartCodeIndex + 4)...(ppsStartCodeIndex + 30) where
            isAtStartCode(pointer: data, startIndex: byte) {
                idrStartCodeIndex = byte
                ppsLength = idrStartCodeIndex - spsLength - 8
                break
        }

        if idrStartCodeIndex == 0 {
            // We made it to the end, PPS must run to end.
            ppsLength = length - ppsStartCodeIndex
            idrStartCodeIndex = length
        }

        // Collate SPS & PPS.
        let parameterSetsData: UnsafeMutablePointer<UnsafePointer<UInt8>> = .allocate(capacity: 2)
        var parameterSetsSizes: [Int] = .init(repeating: 0, count: 2)

        // SPS.
        let spsSrc: UnsafeRawPointer = .init(data) + 4
        let spsDest = malloc(spsLength)
        memcpy(spsDest, spsSrc, spsLength)
        parameterSetsData[0] = .init(.init(spsDest!))
        parameterSetsSizes[0] = spsLength

        // PPS.
        let ppsSrc: UnsafeRawPointer = .init(data) + ppsStartCodeIndex + 4
        let ppsDest = malloc(ppsLength)
        memcpy(ppsDest, ppsSrc, ppsLength)
        parameterSetsData[1] = .init(.init(ppsDest!))
        parameterSetsSizes[1] = ppsLength

        // Create format from parameter sets.
        let error = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil,
                                                                        parameterSetCount: 2,
                                                                        parameterSetPointers: parameterSetsData,
                                                                        parameterSetSizes: parameterSetsSizes,
                                                                        nalUnitHeaderLength: 4,
                                                                        formatDescriptionOut: &self.currentFormat)
        guard error == .zero else { fatalError("CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(error)") }

        // Create the decoder with the given format.
        session = makeDecoder(format: self.currentFormat!)

        // Return new pointer index.
        return idrStartCodeIndex
    }

    /// Makes a new decoder for the given format.
    private func makeDecoder(format: CMFormatDescription) -> VTDecompressionSession {
        // Output format properties.
        var formatKeyCallbacks = kCFTypeDictionaryKeyCallBacks
        var formatValueCallbacks = kCFTypeDictionaryValueCallBacks
        let outputFormat = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &formatKeyCallbacks, &formatValueCallbacks)
        if outputFormat == nil {
            fatalError("Failed to create output format dictionary")
        }

        // Create the session.
        var session: VTDecompressionSession?
        let error = VTDecompressionSessionCreate(allocator: nil,
                                                 formatDescription: format,
                                                 decoderSpecification: nil,
                                                 imageBufferAttributes: nil,
                                                 outputCallback: nil,
                                                 decompressionSessionOut: &session)
        guard error == .zero else { fatalError("Failed to create VTDecompressionSession: \(error)") }

        // Configure for realtime.
        VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        return session!
    }

    func frameCallback(status: OSStatus,
                       flags: VTDecodeInfoFlags,
                       image: CVImageBuffer?,
                       presentation: CMTime,
                       duration: CMTime) {
        // Check status code.
        guard status == .zero else { print("Bad decode: \(status)"); return }

        // Get a CGImage from the decoded pixel buffer.
        var cgImage: CGImage?
        let error = VTCreateCGImageFromCVPixelBuffer(image!, options: nil, imageOut: &cgImage)
        guard error == .zero else { fatalError("Failed to create CGImage: \(error)")}

        // Fire callback with the decoded image.
        callback(cgImage!, presentation.value)
    }

    /// Determines if the current pointer is pointing to the start of a NALU start code.
    func isAtStartCode(pointer: UnsafePointer<UInt8>, startIndex: Int) -> Bool {
        pointer[startIndex] == 0x00 &&
        pointer[startIndex + 1] == 0x00 &&
        pointer[startIndex + 2] == 0x00 &&
        pointer[startIndex + 3] == 0x01
    }
}
