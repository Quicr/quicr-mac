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
                LabeledContent("\(String(describing: ProtocolType.QUIC)) Port") {
                    TextField("relay_port_\(String(describing: ProtocolType.QUIC))",
                              value: $relayConfig.value.quicPort,
                              format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                }
                LabeledContent("\(String(describing: ProtocolType.UDP)) Port") {
                    TextField("relay_port_\(String(describing: ProtocolType.UDP))",
                              value: $relayConfig.value.udpPort,
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
