import SwiftUI

struct NavigationLazyView<Content: View>: View {
    let build: () -> Content
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    var body: Content {
        build()
    }
}

struct SidebarView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: QMediaConfigCall(), label: {
                    HStack {
                        Label("QMedia", systemImage: "phone.circle")
                        Spacer()
                    }
                })

                NavigationLink(destination: NavigationLazyView(
                    InCallView<Loopback>(config: .init(address: "127.0.0.1",
                                                       port: 5001,
                                                       connectionProtocol: .QUIC), onLeave: {})),
                               label: {
                    HStack {
                        Label("Encoded Loopback", systemImage: "arrow.clockwise.circle.fill")
                        Spacer()
                    }
                })

                NavigationLink(destination: SettingsView(), label: {
                    HStack {
                        Label("Settings", systemImage: "gearshape")
                    }
                })
            }
        }.navigationTitle("Application Modes")
    }
}

struct SidebarViewController_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView()
    }
}
