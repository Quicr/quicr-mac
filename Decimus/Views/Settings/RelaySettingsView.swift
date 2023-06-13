import SwiftUI

struct RelaySettingsView: View {

    @AppStorage("relayConfig")
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    var body: some View {
        Section("Relay") {
            Form {
                LabeledContent("Address") {
                    TextField("relay_address", text: $relayConfig.value.address, prompt: Text("localhost"))
                        .keyboardType(.URL)
                }
                ForEach(relayConfig.value.ports.sorted(by: <), id: \.key) { key, _ in
                    LabeledContent("\(String(describing: key)) Port") {
                        TextField("relay_port_\(String(describing: key))",
                                  value: $relayConfig.value.ports[key],
                                  format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    }
                }
            }
            .formStyle(.columns)
        }
    }
}

struct RelaySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            RelaySettingsView()
        }
    }
}
