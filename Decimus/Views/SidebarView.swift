import SwiftUI

struct SidebarView: View {

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

    // iOS 15 fallback
    @available(iOS 16, *)
    struct NavigationDestinationModifier: ViewModifier {
        func body(content: Content) -> some View {
            content
                .navigationDestination(for: ApplicationModeBase.self) { mode in
                    mode.root
                }
        }
    }

    var body: some View {
        SafeNavigationStack {
            List {
                SafeNavigationLink(mode: QMediaPubSub(participants: participants, player: .init(fileWrite: false))) {
                    Label("QMedia", systemImage: "phone.circle")
                }
                SafeNavigationLink(mode: Loopback(participants: participants, player: .init(fileWrite: false))) {
                    Label("Encoded Loopback", systemImage: "arrow.clockwise.circle")
                }
                SafeNavigationLink(mode: RawLoopback(participants: participants, player: .init(fileWrite: false))) {
                    Label("Raw Loopback", systemImage: "arrow.clockwise.circle")
                }
            }.safeNavigationDestination()
        }.navigationTitle("Application Modes")
    }
}

struct SidebarViewController_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
            .environmentObject(VideoParticipants())
    }
}

extension View {
    @ViewBuilder
    func safeNavigationDestination() -> some View {
        if #available(iOS 16, *) {
            self.modifier(SidebarView.NavigationDestinationModifier())
        } else {
            self
        }
    }
}
