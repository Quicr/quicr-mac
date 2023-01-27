import CoreGraphics
import CoreMedia
import SwiftUI

class Loopback : ApplicationModeBase {
    
    let LOCAL_VIDEO_STREAM_ID: UInt32 = 1
    let LOCAL_AUDIO_STREAM_ID: UInt32 = 99
    let LOCAL_MIRROR_PARTICIPANTS: UInt32 = 0
    
    override var root: AnyView {
        set { }
        get { return .init(LoopbackView())}
    }
    
    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        try! data.dataBuffer!.withUnsafeMutableBytes { ptr in
            let unsafe: UnsafePointer<UInt8> = .init(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
            let timestamp = try! data.sampleTimingInfo(at: 0).presentationTimeStamp
            let timestampMs: UInt32 = UInt32(timestamp.seconds * 1000)
            pipeline!.decode(identifier: identifier, data: unsafe, length: data.dataBuffer!.dataLength, timestamp: timestampMs)
        }
    }
    
    override func sendEncodedAudio(identifier: UInt32, data: CMSampleBuffer) {
        // Loopback: Write encoded data to decoder.
        var memory = data
        let address = withUnsafePointer(to: &memory, {UnsafeRawPointer($0)})
        pipeline!.decode(identifier: identifier, data: address.assumingMemoryBound(to: UInt8.self), length: 0, timestamp: 0)
    }
    
    override func encodeCameraFrame(frame: CMSampleBuffer) {
        for id in LOCAL_VIDEO_STREAM_ID...LOCAL_MIRROR_PARTICIPANTS + 1 {
            encodeSample(identifier: id, frame: frame, type: .video) {
                let size = frame.formatDescription!.dimensions
                pipeline!.registerEncoder(identifier: id, width: size.width, height: size.height)
            }
        }
    }
    
    override func encodeAudioSample(sample: CMSampleBuffer) {
        encodeSample(identifier: LOCAL_AUDIO_STREAM_ID, frame: sample, type: .audio) {
            pipeline!.registerEncoder(identifier: LOCAL_AUDIO_STREAM_ID)
        }
    }
    
    private func encodeSample(identifier: UInt32, frame: CMSampleBuffer, type: PipelineManager.MediaType, register: () -> ()) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            register()
            
            // TODO: Since we're in loopback, we can make a decoder upfront too.
            pipeline!.registerDecoder(identifier: identifier, type: type)
        }
        
        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }
}
