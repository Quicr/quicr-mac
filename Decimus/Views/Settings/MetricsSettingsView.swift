import SwiftUI

struct MetricsSettingsView: View {
    static let defaultsKey = "metricsConfig"

    @AppStorage(Self.defaultsKey)
    private var metricsConfig: AppStorageWrapper<MetricsConfig> = .init(value: .init())

    var body: some View {
        Section {
            Form {
                HStack {
                    Text("Submit Metrics")
                    Toggle(isOn: $metricsConfig.value.submit) {}
                }

                HStack {
                    Text("Granular")
                    Toggle(isOn: $metricsConfig.value.granular) {}
                }

                LabeledContent("Interval (s)") {
                    NumberView(value: $metricsConfig.value.intervalSecs,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Interval (s)")
                }

                LabeledContent("Namespace") {
                    TextField("metrics_namespace", text: $metricsConfig.value.namespace, prompt: Text("0x00000000000000000000000000000000/0"))
                }

                LabeledContent("Priority") {
                    NumberView(value: $metricsConfig.value.priority,
                               formatStyle: IntegerFormatStyle<UInt8>.number.grouping(.never),
                               name: "Priorty")
                }

                LabeledContent("TTL") {
                    NumberView(value: $metricsConfig.value.ttl,
                               formatStyle: IntegerFormatStyle<UInt16>.number.grouping(.never),
                               name: "TTL")
                }
            }
            .formStyle(.columns)
        }
    }
}

struct MetricsSettings_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            MetricsSettingsView()
        }
    }
}
