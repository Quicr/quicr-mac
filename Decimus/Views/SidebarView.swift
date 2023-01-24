//
//  SidebarView.swift
//  Decimus
//
//  Navigation sidebar.
//

import SwiftUI

struct SidebarView: View {
    
    @EnvironmentObject private var devices: AudioVideoDevices
    
    var body: some View {
        NavigationView {
            List {
                NavigationLink {
                    CallView().environmentObject(devices)
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
        SidebarView()
    }
}
