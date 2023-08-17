import SwiftUI

struct SubscriptionSettingsView: View {

    @AppStorage("subscriptionConfig")
    private var subscriptionConfig: AppStorageWrapper<SubscriptionConfig> = .init(value: .init())

    var body: some View {
        Section("Subscription Config") {
            Form {
                LabeledContent("Jitter Target Depth (ms)") {
                    TextField(
                        "Depth (ms)",
                        value: $subscriptionConfig.value.jitterDepth,
                        format: .number)
                }
                LabeledContent("Jitter Max Depth (ms)") {
                    TextField(
                        "Depth (ms)",
                        value: $subscriptionConfig.value.jitterMax,
                        format: .number)
                }
                LabeledContent("Opus Window Size (s)") {
                    TextField(
                        "Opus Window Size (s)",
                        value: $subscriptionConfig.value.opusWindowSize,
                        format: .number)
                }
                LabeledContent("Video behaviour") {
                    Picker("Video behaviour", selection: $subscriptionConfig.value.videoBehaviour) {
                        ForEach(VideoBehaviour.allCases) {
                            Text(String(describing: $0))
                        }
                    }.pickerStyle(.segmented)
                }
                HStack {
                    Text("Voice Processing")
                    Toggle(isOn: $subscriptionConfig.value.voiceProcessing) {}
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
    }
}

struct SubscriptionSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            SubscriptionSettingsView()
        }
    }
}
