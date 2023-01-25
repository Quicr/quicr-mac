import SwiftUI
import CoreMedia

let LOCAL_STREAM_ID: UInt32 = 1

/// Wrapper for pipeline as observable object.
class ObservablePipeline: ObservableObject {
    var callback: PipelineManager.DecodedImageCallback? = nil
    var pipeline: PipelineManager? = nil
    
    init(image: ObservableImage) {
        pipeline = .init(
            decodedCallback: { identifier, decoded, timestamp in
                // Push the image to the output.
                DispatchQueue.main.async {
                    image.image = .init(cgImage: decoded)
                }
            },
            encodedCallback: { identifier, data in
                // Loopback: Write encoded data to decoder.
                try! data.dataBuffer!.withUnsafeMutableBytes { ptr in
                    let unsafe: UnsafePointer<UInt8> = .init(ptr.baseAddress!.assumingMemoryBound(to: UInt8.self))
                    let timestamp = try! data.sampleTimingInfo(at: 0).presentationTimeStamp
                    let timestampMs: UInt32 = UInt32(timestamp.seconds * 1000)
                    self.pipeline!.decode(identifier: identifier, data: unsafe, length: data.dataBuffer!.dataLength, timestamp: timestampMs)
                }
            }, debugging: false)
    }
}

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {
    
    let manager: CaptureManager
    
    var done: Bool = false
    
    init(pipeline: ObservablePipeline) {
        manager = .init(callback: { frame in
            
            let manager = pipeline.pipeline!
            
            // Make a encoder for this stream.
            if manager.encoders[1] == nil {
                let size = frame.formatDescription!.dimensions
                manager.registerEncoder(identifier: LOCAL_STREAM_ID, width: size.width, height: size.height)
                
                // TODO: Since we're in loopback, we can make a decoder upfront too.
                manager.registerDecoder(identifier: LOCAL_STREAM_ID)
            }
            
            // Write camera frame to pipeline.
            let buffer: CVImageBuffer? = CMSampleBufferGetImageBuffer(frame)
            guard buffer != nil else { fatalError("Bad camera data?") }
            let timestamp = try! frame.sampleTimingInfo(at:0).presentationTimeStamp
            manager.encode(identifier: LOCAL_STREAM_ID, image: buffer!, timestamp: timestamp)
        })
    }
}

class ObservableImage: ObservableObject {
    @Published var image: UIImage
    
    init() {
        self.image = .init(systemName: "phone")!
    }
}

@main
struct DecimusApp: App {
    @StateObject private var image: ObservableImage
    @StateObject private var pipeline: ObservablePipeline
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager
    
    init() {
        let internalImage = ObservableImage()
        _image = StateObject(wrappedValue: internalImage)
        let line = ObservablePipeline(image: internalImage)
        _pipeline = StateObject(wrappedValue: line)
        _captureManager = StateObject(wrappedValue: ObservableCaptureManager(pipeline: line))
    }
    
    
    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(pipeline)
                .environmentObject(captureManager)
                .environmentObject(image)
        }
    }
}
