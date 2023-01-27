import SwiftUI
import CoreMedia

/// Wrapper for capture manager as observable object.
class ObservableCaptureManager: ObservableObject {
    let manager: CaptureManager
    init(manager: CaptureManager) {
        self.manager = manager
    }
}

@main
struct DecimusApp: App {
    @StateObject private var participants: VideoParticipants
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager
    
    private let app: ApplicationMode
    
    init() {
        // Create an observable object that will track video participants.
        let internalParticipants : VideoParticipants = .init()
        _participants = StateObject(wrappedValue: internalParticipants)
        
        // Application mode to run in.
        // let mode = Loopback(participants: internalParticipants, player: .init())
        let mode = QMediaPubSub(participants: internalParticipants, player: .init())
        
        // Create an observable for the capture device.
        _captureManager = StateObject(wrappedValue: .init(manager: mode.captureManager!))
        app = mode
    }
    
    var body: some Scene {
        WindowGroup {
            SidebarView(rootView: app.root)
                .environmentObject(devices)
                .environmentObject(captureManager)
                .environmentObject(participants)
        }
    }
}
