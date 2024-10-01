// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

@main
struct DecimusApp: App {
    @State var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State var showSidebar = false
    var body: some Scene {
        WindowGroup {
            ZStack {
                ConfigCallView()
                AlertView()
            }
            .preferredColorScheme(.dark)
            #if canImport(UIKit)
            .removeTitleBar()
            #endif
        }
    }
}

#if canImport(UIKit)
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
#endif
