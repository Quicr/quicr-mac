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
    @AppStorage(SettingsView.pttManifestKey)
    private var pttManifest: String = ""
    private let ptt = true

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
                    if !self.ptt {
                        // Video.
                        InCallView(callState: state)
                    } else {
                        // PTT server.
                        if let pttManifest = try? JSONDecoder().decode(PTTManifest.self,
                                                                       from: Data(self.pttManifest.utf8)) {
                            PushToTalkCall(manifest: pttManifest, callState: state)
                        } else {
                            let manifestFile = Bundle.main.url(forResource: "sample_channel_config",
                                                               withExtension: "json")
                            if let data = try? Data(contentsOf: manifestFile!),
                               let pttManifest = try? JSONDecoder().decode(PTTManifest.self, from: data) {
                                PushToTalkCall(manifest: pttManifest, callState: state)
                            } else {
                                Text("Failed to load PTT manifest")
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }.task {
                guard self.state == .notConnected else { return }
                self.state = .connecting
                let startingGroup: UInt64?
                if self.ptt {
                    let id = UIDevice.current.identifierForVendor!
                    let ptr = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 16)
                    defer { ptr.deallocate() }
                    (id as NSUUID).getBytes(ptr.baseAddress!)
                    var sha1 = Insecure.SHA1()
                    sha1.update(bufferPointer: .init(UnsafeMutableRawBufferPointer(ptr)))
                    let digest = sha1.finalize()
                    startingGroup = digest.suffix(8).withUnsafeBytes { ptr in
                        ptr.loadUnaligned(as: UInt64.self).bigEndian & 0x3F_FF_FF_FF_FF_FF_FF_FF
                    }
                } else {
                    startingGroup = nil
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
