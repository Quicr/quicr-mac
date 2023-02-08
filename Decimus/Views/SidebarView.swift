import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var devices: AudioVideoDevices
    @EnvironmentObject private var participants: VideoParticipants

    // iOS 15 fallback.
    struct SafeNavigationStack<T>: View where T: View {
        @ViewBuilder var result: () -> T
        var body: some View {
            if #available(iOS 16, *) {
                NavigationStack(root: result)
            } else {
                NavigationView(content: result)
            }
        }
    }

    // iOS 15 fallback.
    struct SafeNavigationLink<T>: View where T: View {
        @ViewBuilder var label: () -> T
        let mode: ApplicationModeBase

        init(mode: ApplicationModeBase, label: @escaping () -> T) {
            self.mode = mode
            self.label = label
        }

        var body: some View {
            if #available(iOS 16, *) {
               NavigationLink(value: mode, label: label)
            } else {
                NavigationLink(destination: mode.root, label: label)
            }
        }
    }

    var body: some View {
        SafeNavigationStack {
            let list = List {
                SafeNavigationLink(mode: QMediaPubSub(participants: participants, player: .init())) {
                    Label("QMedia", systemImage: "phone.circle")
                }
                SafeNavigationLink(mode: Loopback(participants: participants, player: .init())) {
                    Label("Loopback", systemImage: "arrow.clockwise.circle")
                }
            }
            if #available(iOS 16, *) {
                list.navigationDestination(for: ApplicationModeBase.self) { mode in
                    mode.root
                }
            }
        }.navigationTitle("Application Modes")
    }
}

struct SidebarViewController_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
            .environmentObject(VideoParticipants())
            .environmentObject(ObservableCaptureManager())
    }
}
