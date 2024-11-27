// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct PlaytimeSettings: Codable {
    var playtime = false
    var echo = false
}

struct PlaytimeSettingsView: View {
    static let defaultsKey = "playtime"

    @AppStorage(Self.defaultsKey)
    private var playtimeConfig = AppStorageWrapper<PlaytimeSettings>(value: .init())

    var body: some View {
        Section("Playtime") {
            LabeledToggle("Playtime", isOn: self.$playtimeConfig.value.playtime)
            if self.playtimeConfig.value.playtime {
                LabeledToggle("Echo", isOn: self.$playtimeConfig.value.echo)
            }
        }
    }
}

#Preview {
    PlaytimeSettingsView()
}
