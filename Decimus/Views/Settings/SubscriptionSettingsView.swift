import SwiftUI
import AVFoundation

struct SubscriptionSettingsView: View {

    @AppStorage("subscriptionConfig")
    private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

    @StateObject private var devices = VideoDevices()
    @State private var preferredCamera: String
    private let noPreference = "None"

    init() {
        if #available(iOS 17.0, *) {
            self.preferredCamera = AVCaptureDevice.userPreferredCamera?.uniqueID ?? self.noPreference
        } else {
            self.preferredCamera = self.noPreference
        }
        self.subscriptionConfig.value.videoJitterBuffer.minDepth = self.subscriptionConfig.value.jitterDepthTime
    }

    var body: some View {
        Section("Subscription Config") {
            Form {
                VideoJitterBufferSettingsView(config: $subscriptionConfig.value.videoJitterBuffer)

                LabeledContent("Jitter Target Depth (s)") {
                    TextField(
                        "Depth (s)",
                        value: $subscriptionConfig.value.jitterDepthTime,
                        format: .number)
                        .onChange(of: subscriptionConfig.value.jitterDepthTime) {
                            subscriptionConfig.value.videoJitterBuffer.minDepth = $0
                        }
                }
                LabeledContent("Jitter Max Depth (s)") {
                    TextField(
                        "Depth (s)",
                        value: $subscriptionConfig.value.jitterMaxTime,
                        format: .number)
                }
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
                    }.pickerStyle(.segmented)
                }
                HStack {
                    Text("HEVC override")
                    Toggle(isOn: $subscriptionConfig.value.hevcOverride) {}
                }

                LabeledContent("Encoder bitrate") {
                    Picker("Encoder bitrate", selection: $subscriptionConfig.value.bitrateType) {
                        ForEach(BitrateType.allCases) {
                            Text(String(describing: $0))
                        }
                    }.pickerStyle(.segmented)
                }

                LabeledContent("Data rate limit (multiplier)") {
                    HStack {
                        Slider(value: $subscriptionConfig.value.limit1s,
                               in: 1.0...5.0,
                               step: 0.1) {
                            Text("Data rate limit (multiplier)")
                        }
                        Text(String(format: "%.1fx", subscriptionConfig.value.limit1s))
                            .foregroundColor(.blue)
                    }
                }

                if #available(iOS 17.0, *) {
                    Picker("Preferred Camera", selection: $preferredCamera) {
                        Text("None").tag("None")
                        ForEach(devices.cameras, id: \.uniqueID) {
                            Text($0.localizedName)
                                .tag($0.uniqueID)
                        }.onChange(of: preferredCamera) { _ in
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

                HStack {
                    Text("Single Publication")
                    Toggle(isOn: $subscriptionConfig.value.isSingleOrderedPub) {}
                }

                HStack {
                    Text("Single Subscription")
                    Toggle(isOn: $subscriptionConfig.value.isSingleOrderedSub) {}
                }

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
                    .onChange(of: subscriptionConfig.value.videoJitterBuffer.mode) {
                        if $0 == .layer && subscriptionConfig.value.simulreceive != .none {
                            subscriptionConfig.value.simulreceive = .none
                        }
                    }
                    .onAppear {
                        if subscriptionConfig.value.videoJitterBuffer.mode == .layer && subscriptionConfig.value.simulreceive != .none {
                            subscriptionConfig.value.simulreceive = .none
                        }
                    }
                }

                LabeledContent("Quality miss threshold (frames)") {
                    TextField(
                        "Quality miss threshold (frames)",
                        value: $subscriptionConfig.value.qualityMissThreshold,
                        format: .number)
                }
            }
            .formStyle(.columns)
        }
        Section("Reliability") {
            HStack {
                Text("Audio Publication")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.audio.publication) {}
                Text("Audio Subscription")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.audio.subscription) {}
            }
            HStack {
                Text("Video Publication")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.video.publication) {}
                Text("Video Subscription")
                Toggle(isOn: $subscriptionConfig.value.mediaReliability.video.subscription) {}
            }
        }
        Section("Transport") {
            TransportConfigSettings(quicCwinMinimumKiB: $subscriptionConfig.value.quicCwinMinimumKiB,
                                    quicWifiShadowRttUs: $subscriptionConfig.value.quicWifiShadowRttUs,
                                    timeQueueTTL: $subscriptionConfig.value.timeQueueTTL)
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
