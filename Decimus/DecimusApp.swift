import SwiftUI

@main
struct DecimusApp: App {
    @State var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State var showSidebar = false
    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst)
            NavigationSplitView(columnVisibility: $columnVisibility, sidebar: ErrorView.init) {
                ZStack {
                    ConfigCallView()
                    AlertView()
                }
            }
            .navigationSplitViewStyle(.prominentDetail)
            .preferredColorScheme(.dark)
            .withHostingWindow { window in
                if let titlebar = window?.windowScene?.titlebar {
                    titlebar.titleVisibility = .hidden
                    titlebar.toolbar = nil
                }
            }
            #else
            ZStack {
                ConfigCallView()
                AlertView()
            }
            .preferredColorScheme(.dark)
            #endif
        }
    }
}

extension View {
    fileprivate func withHostingWindow(_ callback: @escaping (UIWindow?) -> Void) -> some View {
        self.background(HostingWindowFinder(callback: callback))
    }
}

private struct HostingWindowFinder: UIViewRepresentable {
    var callback: (UIWindow?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { [weak view] in
            self.callback(view?.window)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
