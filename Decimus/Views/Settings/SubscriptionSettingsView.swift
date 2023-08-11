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
            }
            .formStyle(.columns)
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
