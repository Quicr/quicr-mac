// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct RelaySettingsView: View {
    @AppStorage(RelayConfig.defaultsKey)
    private var relayConfig: AppStorageWrapper<RelayConfig> = .init(value: .init())

    var body: some View {
        Section("Relay") {
            Form {
                LabeledContent("Address") {
                    URLField(name: "relay_address",
                             validation: { url in
                                guard let scheme = url.scheme,
                                      scheme == "moq" else {
                                    return "Must have moq:// scheme"
                                }
                                return nil
                             },
                             url: self.$relayConfig.value.address)
                }
            }
            .formStyle(.columns)
        }
    }
}

struct RelaySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            RelaySettingsView()
        }
    }
}
