// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct PlaytimeSettings: Codable {
    var playtime = false
    var restrictedGridCount = 4
}

struct PlaytimeSettingsView: View {
    static let defaultsKey = "playtime"

    @AppStorage(Self.defaultsKey)
    private var playtimeConfig = AppStorageWrapper<PlaytimeSettings>(value: .init())

    var body: some View {
        Section("Playtime") {
            LabeledToggle("Playtime", isOn: self.$playtimeConfig.value.playtime)
            if self.playtimeConfig.value.playtime {
                Form {
                    LabeledContent("Grid View Max") {
                        NumberView(value: self.$playtimeConfig.value.restrictedGridCount,
                                   formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                                   name: "Grid View Max")
                    }
                }
                .formStyle(.columns)
            }
        }
    }
}

#Preview {
    PlaytimeSettingsView()
}
