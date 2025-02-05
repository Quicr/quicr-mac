// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI
import AVFoundation

struct SubscriptionSettingsView: View {
    static let defaultsKey = "subscriptionConfig"
    static let showLabelsKey = "showLabels"

    @AppStorage(Self.showLabelsKey)
    private var showLabels: Bool = true

    @AppStorage(Self.defaultsKey)
    private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

    @StateObject private var devices = VideoDevices()
    @State private var preferredCamera: String
    private let noPreference = "None"

    init() {
        if #available(iOS 17.0, macOS 13.0, *) {
            self.preferredCamera = AVCaptureDevice.userPreferredCamera?.uniqueID ?? self.noPreference
        } else {
            self.preferredCamera = self.noPreference
        }
        self.subscriptionConfig.value.videoJitterBuffer.minDepth = self.subscriptionConfig.value.jitterDepthTime
    }

    var body: some View {
        Section("Subscription Config") {
            Form {
                LabeledToggle("Show Labels",
                              isOn: self.$showLabels)

                VideoJitterBufferSettingsView(config: $subscriptionConfig.value.videoJitterBuffer)

                LabeledContent("Jitter Target Depth (s)") {
                    TextField(
                        "Depth (s)",
                        value: $subscriptionConfig.value.jitterDepthTime,
                        format: .number)
                        .labelsHidden()
                        .onChange(of: subscriptionConfig.value.jitterDepthTime) { _, new in
                            subscriptionConfig.value.videoJitterBuffer.minDepth = new
                            subscriptionConfig.value.jitterMaxTime = new
                        }
                }
                LabeledContent("Video Jitter Capacity (s)") {
                    TextField(
                        "Capacity (s)",
                        value: $subscriptionConfig.value.videoJitterBuffer.capacity,
                        format: .number)
                        .labelsHidden()
                }
                LabeledToggle("New Audio Buffer",
                              isOn: self.$subscriptionConfig.value.useNewJitterBuffer)
                LabeledToggle("KeyFrame on Update",
                              isOn: self.$subscriptionConfig.value.keyFrameOnUpdate)
                Picker("Opus Window Size (s)", selection: $subscriptionConfig.value.opusWindowSize) {
                    ForEach(OpusWindowSize.allCases) {
                        Text(String(describing: $0))
                    }
                }
                LabeledContent("Video behaviour") {
                    Picker("Video behaviour", selection: $subscriptionConfig.value.videoBehaviour) {
                        ForEach(VideoBehaviour.allCases) {
                            Text(String(describing: $0))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("Encoder bitrate") {
                    Picker("Encoder bitrate", selection: $subscriptionConfig.value.bitrateType) {
                        ForEach(BitrateType.allCases) {
                            Text(String(describing: $0))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("Encoder Key Frame Interval (s)") {
                    TextField("Interval (s)",
                              value: self.$subscriptionConfig.value.keyFrameInterval,
                              format: .number)
                        .labelsHidden()
                }

                LabeledToggle("Stagger Video Qualities",
                              isOn: self.$subscriptionConfig.value.stagger)

                if #available(iOS 17.0, macOS 13.0, tvOS 17.0, *) {
                    LabeledContent("Preferred Camera") {
                        Picker("Preferred Camera", selection: $preferredCamera) {
                            Text("None").tag("None")
                            ForEach(devices.cameras, id: \.uniqueID) {
                                Text($0.localizedName)
                                    .tag($0.uniqueID)
                            }.onChange(of: preferredCamera) {
                                guard self.preferredCamera != self.noPreference else {
                                    AVCaptureDevice.userPreferredCamera = nil
                                    return
                                }

                                for camera in devices.cameras where camera.uniqueID == preferredCamera {
                                    AVCaptureDevice.userPreferredCamera = camera
                                    break
                                }
                            }
                        }
                    }
                }

                LabeledToggle("Single Publication",
                              isOn: $subscriptionConfig.value.isSingleOrderedPub)

                LabeledToggle("Single Subscription",
                              isOn: $subscriptionConfig.value.isSingleOrderedSub)

                LabeledContent("Simulreceive") {
                    Picker("Simulreceive", selection: $subscriptionConfig.value.simulreceive) {
                        ForEach(SimulreceiveMode.allCases) {
                            if subscriptionConfig.value.videoJitterBuffer.mode == .layer && $0 != .none {
                                EmptyView()
                            } else {
                                Text(String(describing: $0))
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: subscriptionConfig.value.videoJitterBuffer.mode) { _, new in
                        if new == .layer && subscriptionConfig.value.simulreceive != .none {
                            subscriptionConfig.value.simulreceive = .none
                        }
                    }
                    .onAppear {
                        if subscriptionConfig.value.videoJitterBuffer.mode == .layer,
                           subscriptionConfig.value.simulreceive != .none {
                            subscriptionConfig.value.simulreceive = .none
                        }
                    }
                }

                LabeledContent("Quality miss threshold (frames)") {
                    NumberView(value: self.$subscriptionConfig.value.qualityMissThreshold,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Threshold")
                }

                LabeledToggle("Do Pause/Resunme",
                              isOn: $subscriptionConfig.value.pauseResume)

                LabeledContent("Pause miss threshold (frames)") {
                    NumberView(value: self.$subscriptionConfig.value.pauseMissThreshold,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Threshold")
                }

                LabeledContent("Cleanup Time (s)") {
                    TextField(
                        "Cleanup Time (s)",
                        value: self.$subscriptionConfig.value.cleanupTime,
                        format: .number)
                        .labelsHidden()
                }
            }
            .formStyle(.columns)
        }
        Section("Reliability") {
            HStack {
                LabeledToggle("Audio Publication",
                              isOn: $subscriptionConfig.value.mediaReliability.audio.publication)
                LabeledToggle("Audio Subscription",
                              isOn: $subscriptionConfig.value.mediaReliability.audio.subscription)
            }
            HStack {
                LabeledToggle("Video Publication",
                              isOn: $subscriptionConfig.value.mediaReliability.video.publication)
                LabeledToggle("Video Subscription",
                              isOn: $subscriptionConfig.value.mediaReliability.video.subscription)
            }
        }
        Section("Security") {
            HStack {
                LabeledToggle("SFrame", isOn: $subscriptionConfig.value.doSFrame)
            }
        }
        Section("Transport") {
            TransportConfigSettings(quicCwinMinimumKiB: $subscriptionConfig.value.quicCwinMinimumKiB,
                                    timeQueueTTL: $subscriptionConfig.value.timeQueueTTL,
                                    chunkSize:
                                        $subscriptionConfig.value.chunkSize,
                                    useResetWaitCC: $subscriptionConfig.value.useResetWaitCC,
                                    useBBR:
                                        $subscriptionConfig.value.useBBR,
                                    quicrLogs: $subscriptionConfig.value.quicrLogs,
                                    enableQlog: $subscriptionConfig.value.enableQlog,
                                    quicPriorityLimit:
                                        $subscriptionConfig.value.quicPriorityLimit)
        }
    }
}

struct SubscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            SubscriptionSettingsView()
        }
    }
}
