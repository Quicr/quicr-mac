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
                        let aiPublish = try! FullTrackName(namespace: ["moq://moq.ptt.arpa/v1",
                                                                       "org/acme",
                                                                       "store/1234",
                                                                       "ai/audio"],
                                                           name: "pcm_en_16khz_mono_i16")
                        let aiAudioReceive = try! FullTrackName(namespace: ["moq://moq.ptt.arpa/v1",
                                                                            "org/acme",
                                                                            "store/1234",
                                                                            "ai/audio"],
                                                                name: "\(state.audioStartingGroup)")
                        let aiTextReceive = try! FullTrackName(namespace: ["moq://moq.ptt.arpa/v1",
                                                                           "org/acme",
                                                                           "store/1234",
                                                                           "ai/text"],
                                                               name: "\(state.audioStartingGroup)")
                        let channel = try! FullTrackName(namespace: ["moq://moq.ptt.arpa/v1",
                                                                     "org/acme",
                                                                     "store/1234",
                                                                     "channel/gardening",
                                                                     "ptt"],
                                                         name: "pcm_en_16khz_mono_i16")
                        // swiftlint:enable force_try
                        PushToTalkCall(manager: manager,
                                       aiPublish: aiPublish,
                                       aiAudioReceive: aiAudioReceive,
                                       aiTextReceive: aiTextReceive,
                                       channel: channel,
                                       callState: state)
                    }
                }
            }.task {
                guard self.state == .notConnected else { return }
                self.state = .connecting
                let id = UIDevice.current.identifierForVendor!
                let ptr = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 16)
                defer { ptr.deallocate() }
                (id as NSUUID).getBytes(ptr.baseAddress!)
                var sha1 = Insecure.SHA1()
                sha1.update(bufferPointer: .init(UnsafeMutableRawBufferPointer(ptr)))
                let digest = sha1.finalize()
                let startingGroup = digest.suffix(8).withUnsafeBytes { ptr in
                    ptr.loadUnaligned(as: UInt64.self).bigEndian & 0x3F_FF_FF_FF_FF_FF_FF_FF
                }
                let state = CallState(config: config, audioStartingGroup: startingGroup) {
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
