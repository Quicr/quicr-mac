import SwiftUI
import CoreMedia

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {
    
    var videoCallback: CaptureManager.MediaCallback? = nil
    var audioCallback: CaptureManager.MediaCallback? = nil
    var manager: CaptureManager? = nil
    
    init() {
        manager = .init(
            cameraCallback: { sample in
                self.videoCallback?(sample)
            },
            audioCallback: { sample in
                self.audioCallback?(sample)
            })
    }
}

@main
struct DecimusApp: App {
    
    @StateObject private var participants: VideoParticipants = .init()
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager  = .init()
    
    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(participants)
                .environmentObject(captureManager)
        }
    }
}
