// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?

    var body: some View {
        if let config = self.config {
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
