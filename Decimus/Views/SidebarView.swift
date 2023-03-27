import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var capture: ObservableCaptureManager
    @EnvironmentObject private var participants: VideoParticipants
    @EnvironmentObject private var modes: Modes

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: modes.qMedia as ApplicationModeBase) {
                    HStack {
                        Label("QMedia", systemImage: "phone.circle")
                        Spacer()
                        if !capture.available {
                            ProgressView()
                        }
                    }
                }.disabled(!capture.available)

                NavigationLink(value: modes.loopback as ApplicationModeBase) {
                    HStack {
                        Label("Encoded Loopback", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        if !capture.available {
                            ProgressView()
                        }
                    }
                }.disabled(!capture.available)

                NavigationLink(value: modes.rawLoopback as ApplicationModeBase) {
                    HStack {
                        Label("Raw Loopback", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        if !capture.available {
                            ProgressView()
                        }
                    }
                }.disabled(!capture.available)
            }.navigationDestination(for: ApplicationModeBase.self) { mode in
                mode.root
            }
        }.navigationTitle("Application Modes")
    }
}

struct SidebarViewController_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
            .environmentObject(VideoParticipants())
    }
}
