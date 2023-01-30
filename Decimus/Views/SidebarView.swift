import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var devices: AudioVideoDevices
    @EnvironmentObject private var participants: VideoParticipants
    @EnvironmentObject private var captureManager: ObservableCaptureManager

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: QMediaPubSub(participants: participants,
                                                   player: .init()) as ApplicationModeBase) {
                    Label("QMedia", systemImage: "phone.circle")
                }
                NavigationLink(value: Loopback(participants: participants, player: .init()) as ApplicationModeBase) {
                    Label("Loopback", systemImage: "arrow.clockwise.circle")
                }
            }.navigationDestination(for: ApplicationModeBase.self) { mode in
                setMode(mode: mode)
            }
        }.navigationTitle("Application Modes")
    }

    func setMode(mode: ApplicationModeBase) -> AnyView {
        captureManager.videoCallback = { sample in
            mode.encodeCameraFrame(frame: sample)
        }
        captureManager.audioCallback = { sample in
            mode.encodeAudioSample(sample: sample)
        }
        return mode.root
    }
}

struct SidebarViewController_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
            .environmentObject(VideoParticipants())
            .environmentObject(ObservableCaptureManager())
    }
}
