import SwiftUI

enum PlayerType: Int, CaseIterable, Identifiable {
    case audioUnit = 0
    case avAudioEngine
    case fasterAvAudioEngine
    var id: Int { rawValue }
}

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
    @AppStorage("playerType") private var playerType: Int = PlayerType.fasterAvAudioEngine.rawValue
    @AppStorage("relayAddress") private var relayAddress: String = RelayURLs.usWest2.rawValue

    @AppStorage("manifestConfig") private var manifestConfig: Data = .init()
    @State private var manifestConfigDefault = ManifestServerConfig(scheme: "https",
                                                                    url: "conf.quicr.ctgpoc.com",
                                                                    port: 411)

    private func saveManifestConfig() {
        guard let configData = try? JSONEncoder().encode(manifestConfigDefault) else { fatalError() }
        self.manifestConfig = configData
        ManifestController.shared.setServer(config: manifestConfigDefault)
    }

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Player", selection: $playerType) {
                    ForEach(PlayerType.allCases) { option in
                        Text(String("\(option)"))
                    }
                }
            }

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
                Picker("Scheme", selection: $manifestConfigDefault.scheme) {
                    ForEach(URLScheme.allCases, id: \.rawValue) { scheme in
                        Text(scheme.rawValue)
                    }
                }
                .onChange(of: manifestConfigDefault.scheme) { _ in
                    saveManifestConfig()
                }

                HStack {
                    Text("Address")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("manifest_address", text: $manifestConfigDefault.url, prompt: Text("127.0.0.1"))
                        .keyboardType(.URL)
                        .onChange(of: manifestConfigDefault.url) { _ in
                            saveManifestConfig()
                        }
                }
                HStack {
                    Text("Port")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("manifest_port", value: $manifestConfigDefault.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .onChange(of: manifestConfigDefault.port) { _ in
                            saveManifestConfig()
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
            do {
                manifestConfigDefault = try JSONDecoder().decode(ManifestServerConfig.self, from: manifestConfig)
                ManifestController.shared.setServer(config: manifestConfigDefault)
            } catch {}
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
