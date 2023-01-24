//
//  CallSetupView.swift
//  Decimus
//
//  Created by Richard Logan on 22/01/2023.
//

import SwiftUI

typealias ConfigCallback = (_ config: CallConfig) -> (Void)

struct CallSetupView: View {
    
    @State private var address: String = ""
    @State private var publishName: String = ""
    @State private var subscribeName: String = ""
    
    
    private var configCallback: ConfigCallback
    
    init(_ onJoin: @escaping ConfigCallback) {
        configCallback = onJoin
    }
    
    var body: some View {
        Text("Real Time Media Client").font(.title)
        Form {
            Section(header: Text("Join a meeting")) {
                TextField("Address", text: $address)
                TextField("Publish Name", text: $publishName)
                TextField("Subscribe Name", text: $subscribeName)
                Button(action: join) {
                    Label("Join", systemImage: "phone")
                }
            }
        }
    }
    
    func join() -> Void {
        configCallback(
            .init(
                address: address,
                publishName: publishName,
                subscribeName: subscribeName))
    }
}

struct CallSetupView_Previews: PreviewProvider {
    
    static func null(_ config: CallConfig) {
    }
    
    static var previews: some View {
        CallSetupView(null)
    }
}
