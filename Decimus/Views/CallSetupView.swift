// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
#if os(tvOS)
import AVFoundation
import AVKit
#endif

private let buttonColour = ActionButtonStyleConfig(
    background: .white,
    foreground: .black
)

private struct LoginForm: View {
    private let logger = DecimusLogger(LoginForm.self)

    @Binding var config: CallConfig?

    @AppStorage("email")
    private var email: String = ""

    @AppStorage(RelaySettingsView.defaultsKey)
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    @AppStorage("confId")
    private var confId: Int?

    @State private var isLoading: Bool = false
    @State private var isAllowedJoin: Bool = false
    @State private var meetings: [UInt32: String] = [:]
    @State private var showContinuityDevicePicker: Bool = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Text("Email")
                    TextField("email", text: self.$email, prompt: Text("example@cisco.com"))
                        #if canImport(UIKit)
                        .keyboardType(.emailAddress)
                        #endif
                        .textFieldStyle(FormInputStyle())
                    if self.isLoading {
                        Spacer()
                        ProgressView()
                    }
                }

                if self.email != "" {
                    VStack(alignment: .leading) {
                        if !self.meetings.isEmpty {
                            HStack {
                                Spacer()
                                Text("Meeting")
                                    .padding(.horizontal)
                                    .foregroundColor(.white)
                                Spacer()
                            }
                            HStack {
                                Spacer()
                                // Ensure the picker will only ever be provided a valid value.
                                if let confId = self.confId,
                                   self.meetings.keys.contains(UInt32(confId)) {
                                    Picker("", selection: self.$confId) {
                                        ForEach(self.meetings.sorted(by: <), id: \.key) { id, meeting in
                                            Text(meeting).tag(Int?(Int(id)))
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .labelsHidden()
                                }
                                Spacer()
                            }
                        } else {
                            Text("No meetings")
                                .padding(.horizontal)
                                .foregroundColor(.white)
                        }
                    }
                }
                if let confId = self.confId {
                    HStack {
                        Spacer()
                        Button("Join Meeting", action: { self.join(conference: UInt32(confId)) })
                            .disabled(!self.isAllowedJoin ||
                                        self.email.isEmpty)
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        Spacer()
                    }
                }
            }
            .listRowBackground(Color.clear)
            #if !os(tvOS)
            .listRowSeparator(.hidden)
            #endif
        }
        .background(.clear)
        #if !os(tvOS)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 480)
        #endif
        .scrollDisabled(true)
        .task {
            // Fetch meetings (and recompute).
            await self.fetchManifest()
        }
        .onChange(of: self.email) {
            Task {
                // Refetch meetings (and recompute).
                await self.fetchManifest()
            }
        }
        .onChange(of: self.meetings) {
            // Recompute.
            self.recompute()
        }
        #if os(tvOS)
        .continuityDevicePicker(isPresented: self.$showContinuityDevicePicker) { device in
        guard let device = device else {
        self.logger.info("No continuity device selected")
        return
        }
        }
        .task {
        self.showContinuityDevicePicker = AVCaptureDevice.default(.continuityCamera,
        for: .video,
        position: .unspecified) == nil
        }
        #endif
    }

    private func fetchManifest() async {
        self.isAllowedJoin = false
        self.isLoading = true
        ManifestController.shared.setServer(config: self.manifestConfig.value)

        do {
            self.meetings = try await ManifestController.shared.getConferences(for: self.email)
                .reduce(into: [:]) { $0[$1.id] = $1.title }
        } catch {
            self.logger.error("Failed to fetch manifest: \(error.localizedDescription)")
            self.isLoading = false
            return
        }
        self.isLoading = false
        self.isAllowedJoin = true
    }

    private func join(conference: UInt32) {
        let relay = self.relayConfig.value
        let config = CallConfig(address: relay.address,
                                email: self.email,
                                conferenceID: conference)
        self.logger.debug("Setting call config: \(config)")
        self.config = config
    }

    private func recompute() {
        // The meeting list has been updated.
        self.isAllowedJoin = false
        guard let first = self.meetings.keys.sorted().first else {
            // There are no available meetings.
            self.logger.debug("No meetings available")
            self.confId = nil
            return
        }

        guard let confId = self.confId else {
            // No meeting selected, fallback.
            self.confId = Int(first)
            self.logger.debug("No meeting selected, fallback to \(first)")
            self.isAllowedJoin = true
            return
        }

        guard self.meetings.keys.contains(UInt32(confId)) else {
            // Invalid meeting selected.
            let missing = confId
            self.confId = Int(first)
            self.logger.warning("\(missing) doesn't exist, fallback to: \(first)")
            self.isAllowedJoin = true
            return
        }
        self.isAllowedJoin = true
        assert(self.meetings.keys.contains(UInt32(self.confId!)))
    }
}

struct CallSetupView: View {
    @Binding var config: CallConfig?
    @State private var settingsOpen: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Image("RTMC-Background")
                    .resizable()
                    .scaledToFill()
                    .edgesIgnoringSafeArea(.top)
                #if targetEnvironment(macCatalyst) || os(macOS)
                .frame(maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center)
                #else
                .frame(width: UIScreen.main.bounds.width,
                height: UIScreen.main.bounds.height,
                alignment: .center)
                #endif

                VStack {
                    Image("RTMC-Icon")
                    Text("Real Time Media Client")
                        .font(.largeTitle)
                        .bold()
                        .foregroundColor(.white)
                        .padding()
                    Text("Join a meeting")
                        .font(.title)
                        .foregroundColor(.white)
                    LoginForm(config: self.$config)
                    #if targetEnvironment(macCatalyst) || os(macOS)
                    .frame(maxWidth: 350)
                    #endif

                    NavigationLink(destination: SettingsView()) {
                        Label("", systemImage: "gearshape").font(.title)
                    }
                    .buttonStyle(ActionButtonStyle(styleConfig: .init(background: .clear, foreground: .white),
                                                   cornerRadius: 50,
                                                   isDisabled: false))
                }
            }
        }
        .onAppear {
            #if canImport(UIKit)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
        }
    }
}

struct CallSetupView_Previews: PreviewProvider {
    static var previews: some View {
        CallSetupView(config: .constant(.init(address: "")))
    }
}
