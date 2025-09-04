// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

struct SettingsView: View {

    @State private var cancelConfirmation = false
    private let logger = DecimusLogger(SettingsView.self)

    static let verboseKey = "verbose"
    @AppStorage(Self.verboseKey)
    private var verbose: Bool = false

    static let recordingKey = "recordCall"
    @AppStorage(Self.recordingKey)
    private var recordCall: Bool = false

    static let mediaInteropKey = "mediaInterop"
    @AppStorage(Self.mediaInteropKey)
    private var mediaInterop: Bool = false

    var body: some View {
        // Reset all.
        HStack {
            Spacer()
            let resetString = "Reset to defaults"
            Button(role: .destructive) {
                self.cancelConfirmation = true
            } label: {
                Text(resetString)
            }
            .confirmationDialog(resetString,
                                isPresented: self.$cancelConfirmation) {
                Button("Reset", role: .destructive) {
                    // Reset all settings to defaults.
                    UserDefaults.standard.removeObject(forKey: RelaySettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: ManifestSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: PlaytimeSettingsView.defaultsKey)
                    do {
                        try InfluxSettingsView.reset()
                    } catch {
                        self.logger.warning("Failed to reset settings: \(error.localizedDescription)", alert: true)
                    }
                    UserDefaults.standard.removeObject(forKey: SubscriptionSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: SettingsView.verboseKey)
                    UserDefaults.standard.removeObject(forKey: SettingsView.mediaInteropKey)
                }
            }
            .buttonStyle(BorderedButtonStyle())
            .padding(.horizontal)
        }
        .padding()

        // Settings.
        Form {
            RelaySettingsView()
                .decimusTextStyle()

            ManifestSettingsView()
                .decimusTextStyle()

            InfluxSettingsView()
                .decimusTextStyle()

            SubscriptionSettingsView()
                .decimusTextStyle()

            Section("Debug") {
                LabeledToggle("Media Interop", isOn: self.$mediaInterop)
                LabeledToggle("Verbose Logging", isOn: self.$verbose)
                #if canImport(ScreenCaptureKit)
                LabeledToggle("Record Call", isOn: self.$recordCall)
                if self.recordCall {
                    DisplayPicker()
                }
                #endif
            }
            .decimusTextStyle()

            PlaytimeSettingsView()
                .decimusTextStyle()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

struct DecimusTextFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            .textFieldStyle(.plain)
        #else
        .textFieldStyle(.roundedBorder)
        #endif
    }
}

extension View {
    func decimusTextStyle() -> some View {
        modifier(DecimusTextFieldStyle())
    }
}
