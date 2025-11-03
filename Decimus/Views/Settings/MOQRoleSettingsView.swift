// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct MoQRoleSettingsView: View {
    static let defaultsKey = "moqRoleConfig"
    private let logger = DecimusLogger(MoQRoleSettingsView.self)

    @AppStorage(Self.defaultsKey)
    private var moqRoleConfig: AppStorageWrapper<MOQRoleConfig> = .init(value: .init())


    var body: some View {
        Section("Protocol") {

            LabeledContent("Role") {
                Picker("MoQ Role", selection: $moqRoleConfig.value.moqRole) {
                    ForEach(MOQRoleType.allCases) { role in
                        Text(String(describing: role)).tag(role)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .onChange(of: moqRoleConfig.value.moqRole) { _, newValue in
                    moqRoleConfig.value.moqRole = defaultMOQRole[(newValue] ?? moqRoleConfig.value.moqRole
                }
            }

        }
        .formStyle(.columns)
    }
}

struct MoQRoleSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            MoQRoleSettingsView()
        }
    }
}

