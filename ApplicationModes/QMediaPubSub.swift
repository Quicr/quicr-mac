import SwiftUI
import CoreMedia

class QMediaPubSub: ApplicationModeBase {
    
    var qMedia: QMedia?
    
    let TEMP_VIDEO_ID = 1
    let TEMP_AUDIO_ID = 2
    
    override var root: AnyView {
        set { }
        get { return .init(QMediaConfigCall(callback: connect))}
    }
    
    func connect(config: CallConfig) {
        qMedia = .init(address: .init(string: config.address)! , port: config.port)
    }
    
    override func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer) {
        try! data.dataBuffer!.withUnsafeMutableBytes { ptr in
            let unsafe: UnsafePointer<UInt8> = .init(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
            let timestamp = try! data.sampleTimingInfo(at: 0).presentationTimeStamp
            let timestampMs: UInt32 = UInt32(timestamp.seconds * 1000)
            // TODO: Add IDR flag.
            qMedia!.sendVideoFrame(mediaStreamId: UInt64(0), buffer: unsafe, length: UInt16(data.dataBuffer!.dataLength), timestamp: UInt64(timestampMs), flag: false)
        }
    }
    
    override func sendEncodedAudio(identifier: UInt32, data: CMSampleBuffer) {
        // TODO: Implement.
    }
    
    override func encodeCameraFrame(frame: CMSampleBuffer) {
        encodeSample(identifier: 1, frame: frame, type: .video) {
            let size = frame.formatDescription!.dimensions
            let subscriptionId = qMedia!.addVideoStreamPublishIntent(codec: .h264)
            pipeline!.registerEncoder(identifier: UInt32(subscriptionId), width: size.width, height: size.height)
            
        }
    }
    
    override func encodeAudioSample(sample: CMSampleBuffer) {
        encodeSample(identifier: 2, frame: sample, type: .audio) {
            let subscriptionId = qMedia!.addAudioStreamPublishIntent(codec: .opus)
            pipeline!.registerEncoder(identifier: UInt32(subscriptionId))
        }
    }
    
    private func encodeSample(identifier: UInt32, frame: CMSampleBuffer, type: PipelineManager.MediaType, register: () -> ()) {
        // Make a encoder for this stream.
        if pipeline!.encoders[identifier] == nil {
            register()
        }
        
        // Write camera frame to pipeline.
        pipeline!.encode(identifier: identifier, sample: frame)
    }
}
