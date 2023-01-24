import SwiftUI

/// Wrapper for pipeline as observable object.
class ObservablePipeline: ObservableObject {
    var callback: PipelineManager.PipelineCallback? = nil
    var pipeline: PipelineManager? = nil
    
    init() {
        pipeline = .init(callback: { identifier, image, timestamp in
            self.callback?(identifier, image, timestamp)
        })
    }
}

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {
    var manager: CaptureManager = .init()
}

@main
struct DecimusApp: App {
    @StateObject private var pipeline = ObservablePipeline()
    @StateObject private var devices = AudioVideoDevices()
    @StateObject private var captureManager = ObservableCaptureManager()
    
    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(pipeline)
                .environmentObject(captureManager)
        }
    }
}
