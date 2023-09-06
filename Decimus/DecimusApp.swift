import SwiftUI

private struct DecimusAppBody: View {
    var body: some View {
        ZStack {
            ConfigCallView()
            AlertView()
        }
    }
}

@main
struct DecimusApp: App {
    @State var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State var showSidebar = false
    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(macCatalyst) && DEBUG
            NavigationSplitView(columnVisibility: $columnVisibility,
                                sidebar: ErrorView.init,
                                detail: DecimusAppBody.init)
                .navigationSplitViewStyle(.prominentDetail)
                .preferredColorScheme(.dark)
                .removeTitleBar()
            #else
            DecimusAppBody()
                .preferredColorScheme(.dark)
                .removeTitleBar()
            #endif
        }
    }
}

extension View {
    fileprivate func withHostingWindow(_ callback: @escaping (UIWindow?) -> Void) -> some View {
        self.background(HostingWindowFinder(callback: callback))
    }

    fileprivate func removeTitleBar() -> some View {
        return withHostingWindow { window in
            #if targetEnvironment(macCatalyst)
            if let titlebar = window?.windowScene?.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
            }
            #endif
        }
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
