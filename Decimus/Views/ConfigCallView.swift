// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ConfigCallView: View {
    private enum _State: Equatable {
        case notConnected
        case connecting
        case connected(CallState)
    }

    @State private var state: _State = .notConnected
    @State private var config: CallConfig?
    private let ptt = true

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
                    if !self.ptt {
                        // Video.
                        InCallView(callState: state)
                    } else {
                        // PTT.
                        let url: URL = .init(string: "http://127.0.0.1:8080")!
                        let manager = MockPushToTalkManager(api: .init(url: url,
                                                                       name: "Rich"))
                        // swiftlint:disable force_try
                        let ai = try! FullTrackName(namespace: ["ai"],
                                                    name: "ai")
                        let channel = try! FullTrackName(namespace: ["channel"],
                                                         name: "channel")
                        // swiftlint:enable force_try
                        PushToTalkCall(manager: manager,
                                       aiChannel: ai,
                                       channel: channel,
                                       moqCallController: state.controller!,
                                       publicationFactory: state.publicationFactory!,
                                       subscriptionFactory: state.subscriptionFactory!)
                    }
                }
            }.task {
                guard self.state == .notConnected else { return }
                self.state = .connecting
                let state = CallState(config: config) {
                    self.state = .notConnected
                    self.config = nil
                }
                let joined = await state.join(make: !self.ptt)
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
