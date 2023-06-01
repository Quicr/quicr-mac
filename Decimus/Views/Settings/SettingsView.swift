import SwiftUI

enum RelayURLs: String {
    case localhost = "localhost"
    case usWest2 = "relay.us-west-2.quicr.ctgpoc.com"
    case euWest2 = "relay.eu-west-2.quicr.ctgpoc.com"
}

let relayConfigs: [RelayURLs: [MediaClient.ProtocolType: UInt16]] = [
    .localhost: [
        .UDP: 1234,
        .QUIC: 1234
    ],
    .usWest2: [
        .UDP: 33434,
        .QUIC: 33435
    ],
    .euWest2: [
        .UDP: 33434,
        .QUIC: 33435
    ]
]

enum URLScheme: String, CaseIterable {
    case http
    case https
}

struct SettingsView: View {
    @AppStorage("relayAddress") private var relayAddress: String = RelayURLs.usWest2.rawValue

    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    var body: some View {
        Form {
            Section("Relay") {
                HStack {
                    Text("Address")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("relay_address", text: $relayAddress, prompt: Text(""))
                        .keyboardType(.URL)
                }
            }

            Section("Manifest") {
                Picker("Scheme", selection: $manifestConfig.value.scheme) {
                    ForEach(URLScheme.allCases, id: \.rawValue) { scheme in
                        Text(scheme.rawValue)
                    }
                }
                .onChange(of: manifestConfig.value.scheme) { _ in
                    ManifestController.shared.setServer(config: manifestConfig.value)
                }

                HStack {
                    Text("Address")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("manifest_address", text: $manifestConfig.value.url, prompt: Text("127.0.0.1"))
                        .keyboardType(.URL)
                        .onChange(of: manifestConfig.value.url) { _ in
                            ManifestController.shared.setServer(config: manifestConfig.value)
                        }
                }
                HStack {
                    Text("Port")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("manifest_port", value: $manifestConfig.value.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .onChange(of: manifestConfig.value.port) { _ in
                            ManifestController.shared.setServer(config: manifestConfig.value)
                        }
                }
            }

            Section(header: Text("Service Configurations")) {
                NavigationLink(destination: InfluxSettings()) {
                    Text("Influx")
                }
            }
        }
        .onAppear {
            ManifestController.shared.setServer(config: manifestConfig.value)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
