// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct ConfigCallView: View {
    @State private var config: CallConfig?

    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    var body: some View {
        if let controller = try? ManifestController(self.manifestConfig.value) {
            if let config = self.config {
                InCallView(config: config, manifest: controller) { self.config = nil }
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            } else {
                CallSetupView(controller) { self.config = $0 }
                #if !os(tvOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
            }
        } else {
            Text("Failed to parse Manifest URL - check settings").foregroundStyle(.red).font(.headline)
        }
    }
}

struct ConfigCall_Previews: PreviewProvider {
    static var previews: some View {
        ConfigCallView()
    }
}
