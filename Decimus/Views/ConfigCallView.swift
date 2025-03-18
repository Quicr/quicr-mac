// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?

    var body: some View {
        if false {
            let url: URL = .init(string: "http://127.0.0.1:5000")!
            let manager = MockPushToTalkManager(api: .init(url: url, name: "Rich"))
            PushToTalkCall(manager: manager,
                           aiChannel: .init(),
                           channel: .init())
            #if !os(tvOS) && !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else if let config = self.config {
            InCallView(config: config) { self.config = nil }
            #if !os(tvOS) && !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } else {
            CallSetupView(config: self.$config)
            #if !os(tvOS) && !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

struct ConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        ConfigCallView()
    }
}
