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

struct SettingsView: View {
    @AppStorage("playerType") private var playerType: Int = PlayerType.avAudioEngine.rawValue
    @AppStorage("relayAddress") private var relayAddress: String = RelayURLs.usWest2.rawValue
    @AppStorage("manifestAddress") private var manifestAddress: String = "127.0.0.1"

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
                }
            }

            Section("Manifest") {
                HStack {
                    Text("Address")
                        .padding(.horizontal)
                        .foregroundColor(.white)
                    TextField("manifest_address", text: $manifestAddress, prompt: Text(""))
                }
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
