import Foundation
import VideoToolbox

/// Decoder callback of image and timestamp.
typealias DecodedImageCallback = (CGImage, CMTimeValue)->()

/// Provides hardware accelerated H264 decoding.
class H264Decoder: Decoder {
    
    // H264 constants.
    private let SPS_TYPE: UInt8 = 7
    private let PPS_TYPE: UInt8 = 8
    
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
        // Current pointer read.
        var offset = 0
        
        // Get NALU type.
        var type = data[4] & 0x1F
        
        // If we don't know the format yet, skip anything except SPS.
        if type != SPS_TYPE && self.currentFormat == nil {
            return
        }
        
        // Extract SPS/PPS if available.
        offset = checkParameterSets(data: data, length: length)
        
        // There might not be any more data left.
        guard offset < length else { return }
        
        // Normal frame handling.
        type = data[offset + 4] & 0x1F
        if type != 1 && type != 5 {
            print("Unhandled NALU type: \(type)")
            return
        }
        
        // Construct the block buffer from the rest of the frame.
        let picLength = length - offset
        let picture = malloc(picLength)
        memcpy(picture, data + offset, picLength)
        
        // Change start code to length
        let picDataLength = UInt32(picLength - 4).bigEndian
        var embedLength = picDataLength
        memcpy(picture, &embedLength, 4)
        
        // Put into CMBlockBuffer
        var buffer: CMBlockBuffer?
        var error = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: picture, blockLength: picLength, blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0, dataLength: picLength, flags: 0, blockBufferOut: &buffer)
        if error != .zero {
            fatalError("CMBlockBufferCreateWithMemoryBlock failed: \(error)")
        }
        
        // CMTime presentation.
        let time = CMTimeMake(value: Int64(timestamp), timescale: 1000)
        var timeInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        
        // Create sample buffer.
        var sampleSize = picLength
        var sampleBuffer: CMSampleBuffer?
        error = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
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
        if error != .zero {
            fatalError("CMSampleBufferCreate failed: \(error)")
        }
        
        // Set to display immediately
        // TODO: Verify this is desired behaviour
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict, unsafeBitCast(kCMSampleAttachmentKey_DisplayImmediately, to: UnsafeRawPointer.self), unsafeBitCast(kCFBooleanTrue, to: UnsafeRawPointer.self))
        
        // Pass sample to decoder.
        let flags: VTDecodeFrameFlags = .init()
        var outputFlags: VTDecodeInfoFlags = .init()
        let decodeError = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sampleBuffer!, flags: flags, infoFlagsOut: &outputFlags, outputHandler: self.frameCallback)
        if decodeError != 0 {
            fatalError("Failed to decode frame: \(error)")
        }
    }
    
    /// Extracts parameter sets from the given pointer, if any.
    private func checkParameterSets(data: UnsafePointer<UInt8>, length: Int) -> Int {
        
        // Get current frame type.
        let type = data[4] & 0x1F
        
        // Is this SPS?
        var ppsStartCodeIndex: Int = 0
        var spsLength: Int = 0
        if type == SPS_TYPE {
            for byte in 4...length - 1 {
                // Find the next start code.
                if isAtStartCode(pointer: data, startIndex: byte) {
                    ppsStartCodeIndex = byte
                    spsLength = ppsStartCodeIndex - 4
                    break
                }
            }
            
            guard ppsStartCodeIndex != 0 else { fatalError("Expected to find PPS start code after SPS") }
        }
        
        // Check for PPS.
        var idrStartCodeIndex: Int = 0
        let secondType = data[ppsStartCodeIndex + 4] & 0x1F
        var ppsLength: Int = 0
        guard secondType == PPS_TYPE else { return idrStartCodeIndex }
        
        // Get PPS.
        for byte in (ppsStartCodeIndex + 4)...(ppsStartCodeIndex + 30) {
            if isAtStartCode(pointer: data, startIndex: byte) {
                idrStartCodeIndex = byte
                ppsLength = idrStartCodeIndex - spsLength - 8
                break
            }
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
        let error = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: parameterSetsData, parameterSetSizes: parameterSetsSizes, nalUnitHeaderLength: 4, formatDescriptionOut: &self.currentFormat)
        if error != 0 {
            fatalError("CMVideoFormatDescriptionCreateFromH264ParameterSets failed: \(error)")
        }
        
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
        let error = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
        if error != .zero {
            fatalError("Failed to create VTDecompressionSession: \(error)")
        }
        
        // Configure for realtime.
        VTSessionSetProperty(session!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        
        // TODO: Can customize pixel transfer properties here.
        
        return session!
    }
    
    func frameCallback(status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, presentation: CMTime, duration: CMTime) {
        // Check status code.
        if status != .zero {
            print("Bad decode: \(status)")
            return
        }
        
        // Get a CGImage from the decoded pixel buffer.
        var cgImage: CGImage? = nil
        let error = VTCreateCGImageFromCVPixelBuffer(image!, options: nil, imageOut: &cgImage)
        if error != .zero {
            fatalError("Failed to create CGImage: \(error)")
        }
        
        // Fire callback with the decoded image.
        callback(cgImage!, presentation.value)
    }
    
    /// Determines if the current pointer is pointing to the start of a NALU start code.
    func isAtStartCode(pointer: UnsafePointer<UInt8>, startIndex: Int) -> Bool {
        pointer[startIndex] == 0x00 && pointer[startIndex + 1] == 0x00 && pointer[startIndex + 2] == 0x00 && pointer[startIndex + 3] == 0x01
    }
}
