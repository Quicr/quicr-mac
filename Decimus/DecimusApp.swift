import SwiftUI
import CoreMedia

let LOCAL_VIDEO_STREAM_ID: UInt32 = 1
let LOCAL_AUDIO_STREAM_ID: UInt32 = 99
let LOCAL_MIRROR_PARTICIPANTS: UInt32 = 1

/// Wrapper for pipeline as observable object.
class ObservablePipeline: ObservableObject {
    var callback: PipelineManager.DecodedImageCallback? = nil
    var pipeline: PipelineManager? = nil
    
    init(participants: VideoParticipants, player: AudioPlayer) {
        pipeline = .init(
            decodedCallback: { identifier, decoded, _ in
                Self.showDecodedImage(identifier: identifier, participants: participants, decoded: decoded)
            },
            encodedCallback: { identifier, data in
                Self.sendEncodedImage(identifier: identifier, data: data, pipeline: self.pipeline!)
            },
            decodedAudioCallback: { _, sample in
                Self.playDecodedAudio(sample: sample, player: player)
            },
            encodedAudioCallback: { identifier, data in
                Self.sendEncodedAudio(identifier: identifier, data: data, pipeline: self.pipeline!)
            },
            debugging: false)
    }
    
    static func showDecodedImage(identifier: UInt32, participants: VideoParticipants, decoded: CGImage) {
        // Push the image to the output.
        DispatchQueue.main.async {
            let participant = participants.getOrMake(identifier: identifier)
            participant.decodedImage = .init(cgImage: decoded)
        }
    }
    
    static func playDecodedAudio(sample: CMSampleBuffer, player: AudioPlayer) {
        player.write(sample: sample)
    }
    
    static func sendEncodedImage(identifier: UInt32, data: CMSampleBuffer, pipeline: PipelineManager) {
        // Loopback: Write encoded data to decoder.
        try! data.dataBuffer!.withUnsafeMutableBytes { ptr in
            let unsafe: UnsafePointer<UInt8> = .init(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
            let timestamp = try! data.sampleTimingInfo(at: 0).presentationTimeStamp
            let timestampMs: UInt32 = UInt32(timestamp.seconds * 1000)
            pipeline.decode(identifier: identifier, data: unsafe, length: data.dataBuffer!.dataLength, timestamp: timestampMs)
        }
    }
    
    static func sendEncodedAudio(identifier: UInt32, data: CMSampleBuffer, pipeline: PipelineManager) {
        // Loopback: Write encoded data to decoder.
        var memory = data
        let address = withUnsafePointer(to: &memory, {UnsafeRawPointer($0)})
        pipeline.decode(identifier: identifier, data: address.assumingMemoryBound(to: UInt8.self), length: 0, timestamp: 0)
    }
}

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {
    
    let manager: CaptureManager
    
    var done: Bool = false
    
    init(pipeline: ObservablePipeline) {
        manager = .init(
            cameraCallback: { frame in
                Self.encodeCameraFrame(frame: frame, pipeline: pipeline.pipeline!)
            },
            audioCallback: { sample in
                Self.encodeAudioSample(sample: sample, pipeline: pipeline.pipeline!)
            })
    }
    
    static func encodeSample(identifier: UInt32, frame: CMSampleBuffer, pipeline: PipelineManager, type: PipelineManager.MediaType, register: () -> ()) {
        // Make a encoder for this stream.
        if pipeline.encoders[identifier] == nil {
            register()
            
            // TODO: Since we're in loopback, we can make a decoder upfront too.
            pipeline.registerDecoder(identifier: identifier, type: type)
        }
        
        // Write camera frame to pipeline.
        pipeline.encode(identifier: identifier, sample: frame)
    }
        
    static func encodeCameraFrame(frame: CMSampleBuffer, pipeline: PipelineManager) {
        for id in LOCAL_VIDEO_STREAM_ID...LOCAL_MIRROR_PARTICIPANTS + 1 {
            encodeSample(identifier: id, frame: frame, pipeline: pipeline, type: .video) {
                let size = frame.formatDescription!.dimensions
                pipeline.registerEncoder(identifier: id, width: size.width, height: size.height)
            }
        }
    }
    
    static func encodeAudioSample(sample: CMSampleBuffer, pipeline: PipelineManager) {
        encodeSample(identifier: LOCAL_AUDIO_STREAM_ID, frame: sample, pipeline: pipeline, type: .audio) {
            pipeline.registerEncoder(identifier: LOCAL_AUDIO_STREAM_ID)
        }
    }
}

@main
struct DecimusApp: App {
    @StateObject private var participants: VideoParticipants
    @StateObject private var pipeline: ObservablePipeline
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager
    
    init() {
        let internalParticipants = VideoParticipants()
        _participants = StateObject(wrappedValue: internalParticipants)
        let line = ObservablePipeline(participants: internalParticipants, player: .init())
        _pipeline = StateObject(wrappedValue: line)
        _captureManager = StateObject(wrappedValue: ObservableCaptureManager(pipeline: line))
    }
    
    
    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(pipeline)
                .environmentObject(captureManager)
                .environmentObject(participants)
        }
    }
}
