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

                LabeledContent("Protocol") {
                    Picker("Protocol", selection: $relayConfig.value.connectionProtocol) {
                        ForEach(ProtocolType.allCases) { prot in
                            Text(String(describing: prot)).tag(prot)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: relayConfig.value.connectionProtocol) { newValue in
                        relayConfig.value.port = defaultProtocolPorts[newValue] ?? relayConfig.value.port
                    }
                }

                LabeledContent("Port") {
                    TextField("relay_port",
                              value: $relayConfig.value.port,
                              format: .number.grouping(.never))
                        .keyboardType(.numberPad)
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
