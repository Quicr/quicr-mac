import SwiftUI
import CoreMedia

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {

    var videoCallback: CaptureManager.MediaCallback?
    var audioCallback: CaptureManager.MediaCallback?
    var manager: CaptureManager?

    init() {
        manager = .init(
            cameraCallback: { identifier, sample in
                self.videoCallback?(identifier, sample)
            },
            audioCallback: { identifier, sample in
                self.audioCallback?(identifier, sample)
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
