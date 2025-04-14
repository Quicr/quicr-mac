// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import CryptoKit
import SwiftUI

struct ConfigCallView: View {
    private enum _State: Equatable {
        case notConnected
        case connecting
        case connected(CallState)
    }

    @State private var state: _State = .notConnected
    @State private var config: CallConfig?
    private let logger = DecimusLogger(ConfigCallView.self)

    var body: some View {
        if let config = self.config {
            // We have config set, time to join.
            Group {
                switch self.state {
                case .connecting, .notConnected:
                    ZStack {
                        Image("RTMC-Background")
                            .resizable()
                            .frame(maxHeight: .infinity,
                                   alignment: .center)
                            .cornerRadius(12)
                            .padding([.horizontal, .bottom])
                        #if os(tvOS)
                        .ignoresSafeArea()
                        #endif
                        ProgressView()
                    }
                case .connected(let state):
                    // Video.
                    InCallView(callState: state)
                }
            }.task {
                guard self.state == .notConnected else { return }
                self.state = .connecting
                let startingGroup: UInt64? = nil
                let state = CallState(config: config, audioStartingGroup: startingGroup) {
                    self.state = .notConnected
                    self.config = nil
                }
                let joined = await state.join(make: true)
                if joined {
                    self.state = .connected(state)
                } else {
                    self.state = .notConnected
                    self.config = nil
                }
            }
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
