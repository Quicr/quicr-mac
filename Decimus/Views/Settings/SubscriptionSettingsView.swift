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
