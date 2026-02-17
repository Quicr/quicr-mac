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

    var body: some View {
        Section("Subscription Config") {
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
            LabeledContent("Jitter Sample Window (s)") {
                TextField(
                    "Window (s)",
                    value: self.$subscriptionConfig.value.videoJitterBuffer.window,
                    format: .number)
                    .labelsHidden()
            }
            LabeledToggle("Adaptive Jitter Buffer",
                          isOn: self.$subscriptionConfig.value.videoJitterBuffer.adaptive)
            LabeledToggle("Experimental WiFi Adaptation",
                          isOn: self.$subscriptionConfig.value.videoJitterBuffer.spikePrediction)
            LabeledToggle("New Audio Buffer",
                          isOn: self.$subscriptionConfig.value.useNewJitterBuffer)
            if self.subscriptionConfig.value.useNewJitterBuffer {
                LabeledContent("Playout Buffer Size (s)") {
                    TextField("Playout Buffer Size (s)",
                              value: self.$subscriptionConfig.value.playoutBufferTime,
                              format: .number)
                        .labelsHidden()
                }
            }
            VStack {
                LabeledToggle("Key Frame on Update",
                              isOn: self.$subscriptionConfig.value.keyFrameOnSubscribeUpdate)
                if self.subscriptionConfig.value.keyFrameOnSubscribeUpdate {
                    HStack {
                        Text("I hope you know what you're doing 😅")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }

            LabeledContent("Fetch before (s)") {
                TextField(
                    "Fetch (s)",
                    value: self.$subscriptionConfig.value.joinConfig.fetchUpperThreshold,
                    format: .number)
                    .labelsHidden()
            }
            LabeledContent("Wait after (s)") {
                TextField(
                    "Wait (s)",
                    value: self.$subscriptionConfig.value.joinConfig.newGroupUpperThreshold,
                    format: .number)
                    .labelsHidden()
            }

            Picker("Opus Window Size (s)", selection: $subscriptionConfig.value.opusWindowSize) {
                ForEach(OpusWindowSize.allCases) {
                    Text(String(describing: $0))
                }
            }
            LabeledContent("Audio PLC Upper Limit (pkts)") {
                TextField("Audio PLC Upper Limit (pkts)",
                          value: self.$subscriptionConfig.value.audioPlcLimit,
                          format: .number)
                    .labelsHidden()
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

            LabeledContent("Preferred Camera") {
                CameraPreferencePicker()
                    .labelsHidden()
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

            LabeledContent("Quality hit threshold (frames)") {
                NumberView(value: self.$subscriptionConfig.value.qualityHitThreshold,
                           formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                           name: "Threshold")
            }

            LabeledToggle("Do Pause/Resume",
                          isOn: $subscriptionConfig.value.pauseResume)

            LabeledToggle("Use Announce Flow",
                          isOn: $subscriptionConfig.value.useAnnounce)

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
            LabeledToggle("SFrame", isOn: $subscriptionConfig.value.sframeSettings.enable)
            if self.subscriptionConfig.value.sframeSettings.enable {
                LabeledContent("SFrame Secret") {
                    TextField(
                        "SFrame Secret",
                        text: self.$subscriptionConfig.value.sframeSettings.key)
                        .labelsHidden()
                }
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
        .onAppear {
            self.subscriptionConfig.value.videoJitterBuffer.minDepth = self.subscriptionConfig.value.jitterDepthTime
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
