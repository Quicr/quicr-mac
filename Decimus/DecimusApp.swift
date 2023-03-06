import SwiftUI
import CoreMedia

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {

    var videoCallback: CaptureManager.MediaCallback?
    var audioCallback: CaptureManager.MediaCallback?
    var deviceChangeCallback: CaptureManager.DeviceChangeCallback?
    var manager: CaptureManager?

    init() {
        manager = .init(
            cameraCallback: { identifier, sample in
                self.videoCallback?(identifier, sample)
            },
            audioCallback: { identifier, sample in
                self.audioCallback?(identifier, sample)
            },
            deviceChangeCallback: { identifier, event in
                self.deviceChangeCallback?(identifier, event)
            })
    }
}

@main
struct DecimusApp: App {

    @StateObject private var participants: VideoParticipants
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager = .init()

    init() {
        let participants: VideoParticipants = .init()
        _participants = .init(wrappedValue: participants)
    }

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(participants)
                .environmentObject(captureManager)
        }
    }
}
