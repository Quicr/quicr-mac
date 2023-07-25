import SwiftUI

struct PortPicker: View {
    private var relayConfig: RelayConfig
    private var callConfig: Binding<CallConfig>
    private var tags: [CallConfig] = []

    init(relayConfig: RelayConfig, callConfig: Binding<CallConfig>, errorWriter: ObservableError) {
        self.relayConfig = relayConfig
        self.callConfig = callConfig
        let config = callConfig.wrappedValue
        if let udp = relayConfig.ports[.UDP] {
            tags.append(CallConfig(address: relayConfig.address,
                                   port: udp,
                                   connectionProtocol: .UDP,
                                   email: config.email,
                                   conferenceID: config.conferenceID))
        } else {
            errorWriter.writeError(message: "Missing UDP configuration port")
        }
        if let quic = relayConfig.ports[.QUIC] {
            tags.append(CallConfig(address: relayConfig.address,
                                   port: quic,
                                   connectionProtocol: .QUIC,
                                   email: config.email,
                                   conferenceID: config.conferenceID))
        } else {
            errorWriter.writeError(message: "Missing QUIC configuration port")
        }
    }

    var body: some View {
        RadioButtonGroup("Protocol",
                         selection: callConfig,
                         labels: ["UDP", "QUIC"],
                         tags: tags)
    }
}

struct PortPicker_Previews: PreviewProvider {
    @State private static var config: CallConfig = .init(address: "",
                                                         port: 0,
                                                         connectionProtocol: .QUIC)
    static var previews: some View {
        PortPicker(relayConfig: RelayConfig(),
                   callConfig: $config,
                   errorWriter: ObservableError())
    }
}
