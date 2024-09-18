// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

enum URLScheme: String, CaseIterable {
    case http
    case https
}

struct ManifestSettingsView: View {
    static let defaultsKey = "manifestConfig"

    @AppStorage(Self.defaultsKey)
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    @State private var configs: [String] = []
    @State private var error: String?
    @State private var showProgressView = false

    var body: some View {
        Section("Manifest") {
            Form {
                LabeledContent("URL") {
                    URLField(name: "URL", validation: nil, url: self.$manifestConfig.value.url)
                }

                HStack {
                    Picker("Config", selection: $manifestConfig.value.config) {
                        ForEach(self.configs, id: \.self) { config in
                            Text(config)
                        }
                    }
                    Spacer()
                    Button {
                        Task(priority: .userInitiated) {
                            await self.refresh()
                        }
                    } label: {
                        if self.showProgressView {
                            ProgressView()
                        } else {
                            Text("Refresh")
                        }
                    }
                }
                if let error = self.error {
                    HStack {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.footnote)
                        Spacer()
                    }
                }
            }
            .formStyle(.columns)
        }
        .task {
            await self.refresh()
        }
        .onChange(of: self.manifestConfig.value) {
            Task(priority: .userInitiated) {
                await self.refresh()
            }
        }
    }

    private func refresh() async {
        let controller: ManifestController
        do {
            controller = try ManifestController(self.manifestConfig.value)
        } catch {
            self.error = error.localizedDescription
            self.configs = []
            return
        }
        self.configs = await self.getConfigs(controller)
    }

    private func getConfigs(_ controller: ManifestController) async -> [String] {
        self.showProgressView = true
        defer { self.showProgressView = false }
        do {
            let configs = try await controller.getConfigs()
            self.error = nil
            let sorted = configs.sorted { $0.configProfile < $1.configProfile }
            return sorted.reduce(into: [], { $0.append($1.configProfile) })
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }
}

struct ManifestSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            ManifestSettingsView()
        }
    }
}
