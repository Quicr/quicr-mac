// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import AVFoundation
import os

@MainActor
struct CallControls: View {
    let captureManager: CaptureManager?
    let engine: DecimusAudioEngine?
    private let logger = DecimusLogger(CallControls.self)

    @Binding var leaving: Bool
    @Binding var showChat: Bool

    @State private var cameraModalExpanded: Bool = false
    @State private var muteModalExpanded: Bool = false
    @State private var alteringDevice: [AVCaptureDevice: Bool] = [:]
    @State private var selectedMicrophone: AVCaptureDevice? = AVCaptureDevice.default(for: .audio)
    @State private var audioOn: Bool = true
    @State private var videoOn: Bool = true
    @State private var talkingWhileMuted: Bool = false

    private let deviceButtonStyleConfig = ActionButtonStyleConfig(
        background: .black,
        foreground: .gray,
        hoverColour: .blue
    )

    private func openCameraModal() {
        cameraModalExpanded.toggle()
        muteModalExpanded = false
    }

    private func openAudioModal() {
        muteModalExpanded.toggle()
        cameraModalExpanded = false
    }

    private func toggleMicrophone() {
        if let engine = self.engine {
            engine.toggleMute()
            self.audioOn = !engine.isInputMuted()
        }
    }

    private func toggleVideos() {
        for camera in self.devices(.video) {
            self.toggleDevice(device: camera)
        }
    }

    private func devices(_ type: AVMediaType? = nil) -> [AVCaptureDevice] {
        do {
            var devices = try self.captureManager?.devices() ?? []
            if let type = type {
                devices = devices.filter { $0.hasMediaType(type) }
            }
            return devices
        } catch {
            self.logger.error("Failed to query devices: \(error.localizedDescription)")
            return []
        }
    }

    private func activeDevices(_ type: AVMediaType? = nil) -> [AVCaptureDevice] {
        do {
            var devices = try self.captureManager?.activeDevices() ?? []
            if let type = type {
                devices = devices.filter { $0.hasMediaType(type) }
            }
            return devices
        } catch {
            self.logger.error("Failed to query active devices: \(error.localizedDescription)")
            return []
        }
    }

    private func toggleDevice(device: AVCaptureDevice) {
        guard !(self.alteringDevice[device] ?? false) else {
            return
        }
        guard let captureManager = self.captureManager else { return }
        self.alteringDevice[device] = true
        do {
            try captureManager.toggleInput(device: device) { enabled in
                DispatchQueue.main.async {
                    self.alteringDevice[device] = false
                    self.videoOn = enabled
                }
            }
        } catch {
            self.logger.error("Failed to toggle device: \(error.localizedDescription)")
        }
    }

    private func isAlteringMicrophone() -> Bool {
        guard self.selectedMicrophone != nil else { return false }
        return self.alteringDevice[self.selectedMicrophone!] ?? false
    }

    var body: some View {
        HStack(alignment: .center) {
            ActionPicker(
                self.audioOn ? "Mute" : self.talkingWhileMuted ? "Talking while muted" : "Unmute",
                icon: self.audioOn ?
                    "microphone-on" :
                    (self.talkingWhileMuted ? "waveform-slash" : "microphone-muted"),
                role: self.audioOn ? nil : .destructive,
                expanded: $muteModalExpanded,
                action: { self.toggleMicrophone() },
                pickerAction: { self.openAudioModal() },
                content: {
                    Text("Audio Connection")
                        .foregroundColor(.gray)
                    ForEach(self.devices(.audio), id: \.uniqueID) { microphone in
                        ActionButton(
                            disabled: self.isAlteringMicrophone(),
                            cornerRadius: 12,
                            styleConfig: self.deviceButtonStyleConfig,
                            action: { self.toggleDevice(device: microphone) },
                            title: {
                                HStack {
                                    Image(systemName: microphone.deviceType == .microphone ?
                                            "mic" : "speaker.wave.2")
                                        .renderingMode(.original)
                                        .foregroundColor(.gray)
                                    Text(microphone.localizedName).tag(microphone)
                                }
                            })
                            .aspectRatio(contentMode: .fill)
                    }
                })
                .onChange(of: self.selectedMicrophone) {
                    guard let microphone = self.selectedMicrophone else { return }
                    self.toggleDevice(device: microphone)
                }
                .disabled(self.isAlteringMicrophone())

            ActionPicker(
                self.videoOn ? "Stop Video" : "Start Video",
                icon: self.videoOn ? "video-on" : "video-off",
                role: self.videoOn ? nil : .destructive,
                expanded: $cameraModalExpanded,
                action: { self.toggleVideos() },
                pickerAction: { self.openCameraModal() },
                content: {
                    LazyVGrid(columns: [GridItem(.fixed(16)), GridItem(.flexible())],
                              alignment: .leading) {
                        Image("video-on")
                            .renderingMode(.template)
                            .foregroundColor(.gray)
                        Text("Camera")
                            .padding(.leading)
                            .foregroundColor(.gray)
                        ForEach(self.devices(.video), id: \.self) { camera in
                            if self.alteringDevice[camera] ?? false {
                                ProgressView()
                            } else if self.devices(.video).contains(camera) {
                                Image(systemName: "checkmark")
                            } else {
                                Spacer()
                            }
                            ActionButton(
                                disabled: self.alteringDevice[camera] ?? false,
                                cornerRadius: 10,
                                styleConfig: self.deviceButtonStyleConfig,
                                action: { self.toggleDevice(device: camera) },
                                title: {
                                    Text(verbatim: camera.localizedName)
                                        .lineLimit(1)
                                }
                            )
                        }
                    }
                    .frame(maxWidth: 300, alignment: .bottomTrailing)
                    .padding(.bottom)
                })
                .disabled(self.devices(.video).allSatisfy { !(self.alteringDevice[$0] ?? false) })

            Button(action: {
                self.showChat = true
            }, label: {
                Image(systemName: "message")
                    .renderingMode(.template)
                    .foregroundColor(.white)
                    .padding()
            })
            .foregroundColor(.white)
            .background(.blue)
            .clipShape(Circle())

            Button(action: {
                leaving = true
                muteModalExpanded = false
                cameraModalExpanded = false
            }, label: {
                Image("cancel")
                    .renderingMode(.template)
                    .foregroundColor(.white)
                    .padding()
            })
            .foregroundColor(.white)
            .background(.red)
            .clipShape(Circle())
        }
        .frame(maxWidth: 650)
        .scaledToFit()
        .onAppear {
            self.audioOn = !(self.engine?.isInputMuted() ?? true)

            #if !os(macOS)
            if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *) {
                guard let engine = self.engine else { return }
                do {
                    try engine.setMutedSpeechActivityEventListener { voiceEvent in
                        switch voiceEvent {
                        case .started:
                            DispatchQueue.main.async {
                                self.talkingWhileMuted = true
                            }
                            self.logger.info("Talking while muted")
                        case .ended:
                            DispatchQueue.main.async {
                                self.talkingWhileMuted = false
                            }
                            self.logger.info("Stopped talking while muted")
                        default:
                            break
                        }
                    }
                } catch {
                    self.logger.error("Unable to set muted speech activity listener")
                }
            }
            #endif
        }
        .onDisappear {
            #if !os(macOS)
            if #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, visionOS 1.0, *) {
                do {
                    try self.engine?.setMutedSpeechActivityEventListener(nil)
                } catch {
                    self.logger.warning("Unable to unset muted speech activity listener")
                }
            }
            #endif
        }
    }
}

#Preview {
    let bool: Binding<Bool> = .init(get: { return false }, set: { _ in })
    let showChat: Binding<Bool> = .constant(false)
    let capture: CaptureManager? = try? .init(metricsSubmitter: MockSubmitter(), granularMetrics: false)
    CallControls(captureManager: capture,
                 engine: try! .init(), // swiftlint:disable:this force_try
                 leaving: bool,
                 showChat: showChat)
}
