import SwiftUI

enum PlayerType: Int, CaseIterable, Identifiable {
    case audioUnit = 0
    case avAudioEngine
    case fasterAvAudioEngine
    var id: Int { rawValue }
}

struct SettingsView: View {
    @AppStorage("playerType") private var playerType: Int = PlayerType.fasterAvAudioEngine.rawValue

    var body: some View {
        Form {
            Section(header: Text("Audio Playout")) {
                Picker(selection: $playerType) {
                    ForEach(PlayerType.allCases) { option in
                        Text(String("\(option)"))
                    }
                } label: {
                    Text("Player")
                    Text("Which audio player to use")
                }
            }

            Section(header: Text("Service Configurations")) {
                NavigationLink(destination: InfluxSettings()) {
                    Text("Influx")
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
