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

class Modes: ObservableObject {

    let qMedia: QMediaPubSub
    let loopback: Loopback
    let rawLoopback: RawLoopback

    init(participants: VideoParticipants) {
        let player: AudioPlayer = .init(fileWrite: false)
        qMedia = .init(participants: participants, player: player)
        loopback = .init(participants: participants, player: player)
        rawLoopback = .init(participants: participants, player: player)
    }
}

@main
struct DecimusApp: App {

    @StateObject private var participants: VideoParticipants
    @StateObject private var devices: AudioVideoDevices = .init()
    @StateObject private var captureManager: ObservableCaptureManager = .init()
    @StateObject private var modes: Modes

    init() {
        let participants: VideoParticipants = .init()
        _participants = .init(wrappedValue: participants)
        _modes = .init(wrappedValue: .init(participants: participants))
    }

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .environmentObject(devices)
                .environmentObject(participants)
                .environmentObject(captureManager)
                .environmentObject(modes)
        }
    }
}
