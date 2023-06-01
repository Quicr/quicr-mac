import SwiftUI

enum PlayerType: Int, CaseIterable, Identifiable {
    case audioUnit = 0
    case avAudioEngine
    case fasterAvAudioEngine
    var id: Int { rawValue }
}

struct SettingsView: View {
    @AppStorage("playerType")
    private var playerType: Int = PlayerType.fasterAvAudioEngine.rawValue

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Player", selection: $playerType) {
                    ForEach(PlayerType.allCases) { option in
                        Text(String("\(option)"))
                    }
                }
            }

            RelaySettingsView()
                .textFieldStyle(.roundedBorder)

            ManifestSettingsView()
                .textFieldStyle(.roundedBorder)

            InfluxSettingsView()
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 500)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
