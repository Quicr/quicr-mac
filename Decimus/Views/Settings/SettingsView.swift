// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
#if canImport(ScreenCaptureKit) && (os(macOS) || targetEnvironment(macCatalyst))
import ScreenCaptureKit
#endif

struct SettingsView: View {

    @State private var cancelConfirmation = false
    private let logger = DecimusLogger(SettingsView.self)

    @AppStorage(AppSettings.verbose.key)
    private var verbose = AppSettings.verbose.defaultValue

    @AppStorage(AppSettings.recording.key)
    private var recordCall = AppSettings.recording.defaultValue

    @AppStorage(AppSettings.mediaInterop.key)
    private var mediaInterop = AppSettings.mediaInterop.defaultValue

    @AppStorage(AppSettings.useOverrideNamespace.key)
    private var useOverrideNamespace = AppSettings.useOverrideNamespace.defaultValue

    @AppStorage(AppSettings.overrideNamespace.key)
    private var overrideNamespace = AppSettings.overrideNamespace.defaultValue

    @AppStorage(AppSettings.subscribeNamespaceEnabled.key)
    private var subscribeNamespaceEnabled = AppSettings.subscribeNamespaceEnabled.defaultValue

    @AppStorage(AppSettings.subscribeNamespace.key)
    private var subscribeNamespace = AppSettings.subscribeNamespace.defaultValue

    @AppStorage(AppSettings.subscribeNamespaceAccept.key)
    private var subscribeNamespaceAccept = AppSettings.subscribeNamespaceAccept.defaultValue

    @AppStorage(AppSettings.moqRole.key)
    private var moqRole = AppSettings.moqRole.defaultValue

    @AppStorage(AppSettings.appExtensionMode.key)
    private var appExtensionMode = AppSettings.appExtensionMode.defaultValue

    // Audio demo settings.
    // TODO: Probably smarten this up a bit.

    @AppStorage(AppSettings.demoEnabled.key)
    private var demoEnabled = AppSettings.demoEnabled.defaultValue

    @AppStorage(AppSettings.demoMeetingId.key)
    private var demoMeetingId = AppSettings.demoMeetingId.defaultValue

    @AppStorage(AppSettings.demoMaxTracksSelected.key)
    private var demoMaxTracksSelected = AppSettings.demoMaxTracksSelected.defaultValue

    @AppStorage(AppSettings.demoTimeout.key)
    private var demoTimeout = AppSettings.demoTimeout.defaultValue

    @AppStorage(AppSettings.demoTimeToSpeechStart.key)
    private var demoTimeToSpeechStart = AppSettings.demoTimeToSpeechStart.defaultValue

    @AppStorage(AppSettings.demoTimeToContinuous.key)
    private var demoTimeToContinuous = AppSettings.demoTimeToContinuous.defaultValue

    @AppStorage(AppSettings.demoTimeToDropStart.key)
    private var demoTimeToDropStart = AppSettings.demoTimeToDropStart.defaultValue

    @AppStorage(AppSettings.demoTimeToDropContinuous.key)
    private var demoTimeToDropContinuous = AppSettings.demoTimeToDropContinuous.defaultValue

    @AppStorage(AppSettings.demoVadRollSubgroup.key)
    private var demoVadRollSubgroup = AppSettings.demoVadRollSubgroup.defaultValue

    @AppStorage(AppSettings.demoVadAggressiveness.key)
    private var demoVadAggressiveness = AppSettings.demoVadAggressiveness.defaultValue

    @State private var overrideError: String?
    @State private var subscribeNamespaceError: String?
    @State private var subscribeNamespaceAcceptError: String?

    private var vadTuningProfile: Binding<VADTuningProfile> {
        .init {
            let current = VADTuningProfile.Values(timeToSpeechStart: self.demoTimeToSpeechStart,
                                                  timeToContinuous: self.demoTimeToContinuous,
                                                  timeToDropStart: self.demoTimeToDropStart,
                                                  timeToDropContinuous: self.demoTimeToDropContinuous,
                                                  vadAggressiveness: self.demoVadAggressiveness)
            return VADTuningProfile.allCases.first { $0.values == current } ?? .custom
        } set: { profile in
            guard let values = profile.values else { return }
            self.demoTimeToSpeechStart = values.timeToSpeechStart
            self.demoTimeToContinuous = values.timeToContinuous
            self.demoTimeToDropStart = values.timeToDropStart
            self.demoTimeToDropContinuous = values.timeToDropContinuous
            self.demoVadAggressiveness = values.vadAggressiveness
        }
    }

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
                    do {
                        try InfluxSettingsView.reset()
                    } catch {
                        self.logger.warning("Failed to reset settings: \(error.localizedDescription)", alert: true)
                    }
                    if let bundleID = Bundle.main.bundleIdentifier {
                        UserDefaults.standard.removePersistentDomain(forName: bundleID)
                    } else {
                        self.logger.error("Failed to reset settings: missing bundle ID")
                    }
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
                LabeledContent("MoQ Role") {
                    Picker("MoQ Role", selection: self.$moqRole) {
                        ForEach(MoQRole.allCases) { role in
                            Text(role.description).tag(role)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                LabeledContent("App Extensions") {
                    Picker("App Extensions", selection: self.$appExtensionMode) {
                        ForEach(AppExtensionMode.allCases) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                LabeledToggle("Media Interop", isOn: self.$mediaInterop)
                LabeledToggle("Override Namespace", isOn: self.$useOverrideNamespace)
                if self.useOverrideNamespace {
                    LabeledContent("Namespace") {
                        VStack {
                            TextField("Override Namespace",
                                      text: self.$overrideNamespace)
                                .autocorrectionDisabled()
                                #if !os(macOS)
                                .keyboardType(.asciiCapable)
                            #endif
                            if let overrideError {
                                Text(overrideError)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }
                    .onChange(of: self.overrideNamespace) {
                        if let error = CallState.validateNamespace(self.overrideNamespace, placeholder: true).error {
                            self.overrideError = error
                        } else {
                            self.overrideError = nil
                        }
                    }
                }

                LabeledToggle("Subscribe Namespace Prefix", isOn: self.$subscribeNamespaceEnabled)
                if self.subscribeNamespaceEnabled {
                    LabeledContent("Subscribe Namespace") {
                        VStack {
                            TextField("Subscribe Namespace",
                                      text: self.$subscribeNamespace)
                                .autocorrectionDisabled()
                                #if !os(macOS)
                                .keyboardType(.asciiCapable)
                            #endif
                            if let subscribeNamespaceError {
                                Text(subscribeNamespaceError)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }
                    .onChange(of: self.subscribeNamespace) {
                        if let error = CallState.validateNamespace(self.subscribeNamespace, placeholder: false).error {
                            self.subscribeNamespaceError = error
                        } else {
                            self.subscribeNamespaceError = nil
                        }
                    }

                    LabeledContent("Prefix to Accept") {
                        VStack {
                            TextField("Subscribe Namespace Accept",
                                      text: self.$subscribeNamespaceAccept)
                                .autocorrectionDisabled()
                                #if !os(macOS)
                                .keyboardType(.asciiCapable)
                            #endif
                            if let subscribeNamespaceAcceptError {
                                Text(subscribeNamespaceAcceptError)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }
                    .onChange(of: self.subscribeNamespaceAccept) {
                        if let error = CallState.validateNamespace(self.subscribeNamespaceAccept,
                                                                   placeholder: false).error {
                            self.subscribeNamespaceAcceptError = error
                        } else {
                            self.subscribeNamespaceAcceptError = nil
                        }
                    }
                }

                LabeledToggle("Verbose Logging", isOn: self.$verbose)
                #if canImport(ScreenCaptureKit) && (os(macOS) || targetEnvironment(macCatalyst))
                LabeledToggle("Record Call", isOn: self.$recordCall)
                if self.recordCall {
                    DisplayPicker()
                }
                #endif
            }
            .decimusTextStyle()

            Section("Demo") {
                LabeledToggle("Audio Activity Demo", isOn: self.$demoEnabled)
                if self.demoEnabled {
                    LabeledContent("Meeting ID") {
                        TextField("Meeting ID", text: self.$demoMeetingId)
                            .autocorrectionDisabled()
                            #if !os(macOS)
                            .keyboardType(.asciiCapable)
                        #endif
                    }
                }
            }
            .decimusTextStyle()

            Section("Top-N Filtering") {
                LabeledContent("Max Tracks Selected") {
                    TextField("Max Tracks Selected", value: self.$demoMaxTracksSelected, format: .number)
                        #if !os(macOS)
                        .keyboardType(.numberPad)
                    #endif
                }
                LabeledContent("Timeout (s)") {
                    TextField("Timeout (s)", value: self.$demoTimeout, format: .number)
                        #if !os(macOS)
                        .keyboardType(.decimalPad)
                    #endif
                }
                LabeledContent("VAD Tuning") {
                    Picker("VAD Tuning", selection: self.vadTuningProfile) {
                        ForEach(VADTuningProfile.allCases) { profile in
                            Text(profile.label).tag(profile)
                                .disabled(profile == .custom)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                LabeledContent("Time to Speech Start (s)") {
                    TextField("Time to Speech Start (s)", value: self.$demoTimeToSpeechStart, format: .number)
                        #if !os(macOS)
                        .keyboardType(.decimalPad)
                    #endif
                }
                LabeledContent("Time to Continuous (s)") {
                    TextField("Time to Continuous (s)", value: self.$demoTimeToContinuous, format: .number)
                        #if !os(macOS)
                        .keyboardType(.decimalPad)
                    #endif
                }
                LabeledContent("Time to Drop Start (s)") {
                    TextField("Time to Drop Start (s)", value: self.$demoTimeToDropStart, format: .number)
                        #if !os(macOS)
                        .keyboardType(.decimalPad)
                    #endif
                }
                LabeledContent("Time to Drop Continuous (s)") {
                    TextField("Time to Drop Continuous (s)", value: self.$demoTimeToDropContinuous, format: .number)
                        #if !os(macOS)
                        .keyboardType(.decimalPad)
                    #endif
                }
                LabeledToggle("VAD Roll Subgroup", isOn: self.$demoVadRollSubgroup)
                LabeledContent("VAD Aggressiveness") {
                    Picker("VAD Aggressiveness", selection: self.$demoVadAggressiveness) {
                        Text("Quality (0)").tag(0)
                        Text("Low Bitrate (1)").tag(1)
                        Text("Aggressive (2)").tag(2)
                        Text("Very Aggressive (3)").tag(3)
                    }
                    .labelsHidden()
                }
            }
            .decimusTextStyle()

            PlaytimeSettingsView()
                .decimusTextStyle()
        }
        .formStyle(.grouped)
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
