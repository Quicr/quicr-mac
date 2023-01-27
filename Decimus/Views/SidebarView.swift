//
//  SidebarView.swift
//  Decimus
//
//  Navigation sidebar.
//

import SwiftUI

struct SidebarView: View {
    
    @EnvironmentObject private var devices: AudioVideoDevices
    
    private let rootView: AnyView
    
    init(rootView: AnyView) {
        self.rootView = rootView
    }
    
    var body: some View {
        NavigationView {
            List {
                NavigationLink {
                    rootView.environmentObject(devices)
                } label: {
                    Label("Call", systemImage: "phone.circle")
                }
            }
            .listStyle(SidebarListStyle())
        }
    }
}

struct SidebarViewController_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView(rootView: .init(EmptyView()))
    }
}
