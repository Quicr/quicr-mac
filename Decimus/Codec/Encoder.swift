import VideoToolbox
import CoreVideo

class Encoder {
    
    typealias EncodedDataCallback = (CMSampleBuffer)->()
    
    private var encoder: VTCompressionSession?
    private let callback: EncodedDataCallback
    
    // TODO: Maximum H265.
    
    init(width: Int32, height: Int32, callback: @escaping EncodedDataCallback) {
        self.callback = callback
        let error = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder)
        guard error == .zero else {
            fatalError("Encoder creation failed")
        }
        
        let realtimeError = VTSessionSetProperty(encoder!, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        guard realtimeError == .zero else { fatalError("Failed to set encoder to realtime") }
    }
    
    func write(image: CVImageBuffer, timestamp: CMTime) {
        VTCompressionSessionEncodeFrame(
            encoder!,
            imageBuffer: image,
            presentationTimeStamp: timestamp,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil,
            outputHandler: self.encoded)
    }
    
    func encoded(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard status == .zero else { fatalError("Encode failure")}
        guard sample != nil else { fatalError("Encode returned nil sample?")}
        
        // Annex B time.
        let attachments: NSArray = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: false)! as NSArray
        var idr = false
        let sampleAttachments = attachments[0] as! NSDictionary
        let key = kCMSampleAttachmentKey_NotSync as NSString
        if let found = sampleAttachments[key] as? Bool? {
            idr = !(found != nil && found == true)
        }
        
        let START_CODE_LENGTH = 4
        let START_CODE = [ 0x00, 0x00, 0x00, 0x01 ]
        
        if idr {
            // Get number of parameter sets.
            var sets: Int = 0
            let format = CMSampleBufferGetFormatDescription(sample!)
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format!,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &sets,
                nalUnitHeaderLengthOut: nil)
            
            // Get actual parameter sets.
            var parameterSetPointers: [UnsafePointer<UInt8>] = .init()
            var parameterSetLengths: [Int] = .init()
            for i in 0...sets-1  {
                var parameterSet: UnsafePointer<UInt8>?
                var parameterSize: Int = 0
                var naluSizeOut: Int32 = 0
                
                let formatError = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format!,
                    parameterSetIndex: i,
                    parameterSetPointerOut: &parameterSet,
                    parameterSetSizeOut: &parameterSize,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &naluSizeOut)
                guard formatError == .zero else { fatalError("Couldn't get description: \(formatError) [] \(i)") }
    
                parameterSetPointers.append(parameterSet!)
                parameterSetLengths.append(parameterSize)
                
                guard naluSizeOut == START_CODE_LENGTH else { fatalError("Unexpected start code length?") }
            }
            
            // Compute total ANNEX B parameter set size.
            var totalLength = START_CODE_LENGTH * sets
            for length in parameterSetLengths {
                totalLength += length
            }
            
            // Make a block buffer for PPS/SPS.
            var buffer: CMBlockBuffer?
            let blockError = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: totalLength,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: totalLength,
                flags: 0,
                blockBufferOut: &buffer)
            guard blockError == .zero else { fatalError("Failed to create parameter set block") }
            
            let allocateError = CMBlockBufferAssureBlockMemory(buffer!)
            guard allocateError == .zero else { fatalError("Failed to allocate parameter set block") }
            
            var offset = 0
            for i in 0...sets-1  {
                let startCodeError = CMBlockBufferReplaceDataBytes(with: START_CODE, blockBuffer: buffer!, offsetIntoDestination: offset, dataLength: START_CODE_LENGTH)
                guard startCodeError == .zero else { fatalError("Couldn't copy start code") }
                offset += START_CODE_LENGTH
                let parameterDataError = CMBlockBufferReplaceDataBytes(with: parameterSetPointers[i], blockBuffer: buffer!, offsetIntoDestination: offset, dataLength: parameterSetLengths[i])
                guard parameterDataError == .zero else { fatalError("Couldn't copy parameter data") }
                offset += parameterSetLengths[i]
            }
            
            // TODO: Why?
            try! buffer!.withUnsafeMutableBytes { ptr in
                let firstAlterIndex = START_CODE_LENGTH - 1
                ptr[firstAlterIndex] = 0x01
                let secondAlterIndex = START_CODE_LENGTH * 2 + parameterSetLengths[0] - 1
                ptr[secondAlterIndex] = 0x01
            }
            
            // TODO: Faked a sample for easy callback.
            var time = try! sample!.sampleTimingInfo(at: 0)
            var parameterSample: CMSampleBuffer?
            let sampleError = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: buffer,
                formatDescription: nil,
                sampleCount: 1,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &time,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &totalLength,
                sampleBufferOut: &parameterSample)
            guard sampleError == .zero else { fatalError("Couldn't create parameter sample") }
            callback(parameterSample!)
        }
        
        let buffer = sample!.dataBuffer!
        var offset = 0
        while offset < buffer.dataLength - START_CODE_LENGTH {
            guard let memory = malloc(START_CODE_LENGTH) else { fatalError("malloc fail") }
            var data: UnsafeMutablePointer<CChar>? = nil
            let accessError = CMBlockBufferAccessDataBytes(buffer, atOffset: offset, length: 4, temporaryBlock: memory, returnedPointerOut: &data)
            guard accessError == .zero else { fatalError("Bad access") }
            guard data != nil else { fatalError("Bad access") }
            
            var naluLength: UInt32 = 0
            memcpy(&naluLength, data, START_CODE_LENGTH)
            free(memory)
            naluLength = CFSwapInt32BigToHost(naluLength)
            
            // Replace with start code.
            let replaceError = CMBlockBufferReplaceDataBytes(with: START_CODE, blockBuffer: buffer, offsetIntoDestination: offset, dataLength: 4)
            guard replaceError == .zero else { fatalError("Replace") }
            
            // Carry on.
            offset += START_CODE_LENGTH + Int(naluLength)
        }
        
        // Callback the Annex-B sample.
        callback(sample!)
    }
}
