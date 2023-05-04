import SwiftUI

enum PlayerType: Int, CaseIterable, Identifiable {
    case audioUnit = 0
    case avAudioEngine
    case fasterAvAudioEngine
    var id: Int { rawValue }
}

struct SettingsView: View {
    @AppStorage("playerType") private var playerType: Int = PlayerType.avAudioEngine.rawValue

    var body: some View {
        Form {
            Picker("Player", selection: $playerType) {
                ForEach(PlayerType.allCases) { option in
                    Text(String("\(option)"))
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
