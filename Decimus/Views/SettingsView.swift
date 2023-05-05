import SwiftUI

enum PlayerType: Int {
    case audioUnit = 0
    case avAudioEngine
}

struct SettingsView: View {
    @AppStorage("playerType") private var playerType: Int = PlayerType.avAudioEngine.rawValue
    @State private var toggle = false

    var body: some View {
        let binding: Binding = .init {
            playerType == PlayerType.audioUnit.rawValue
        } set: { value in
            if value {
                playerType = PlayerType.audioUnit.rawValue
            } else {
                playerType = PlayerType.avAudioEngine.rawValue
            }
        }

        Form {
            Toggle("Use AudioUnit Player", isOn: binding)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
