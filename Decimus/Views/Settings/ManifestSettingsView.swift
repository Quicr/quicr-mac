import SwiftUI

enum URLScheme: String, CaseIterable {
    case http
    case https
}

struct ManifestSettingsView: View {
    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())
    
    @State private var configs: [String] = []

    var body: some View {
        Section("Manifest") {
            Form {
                LabeledContent("Scheme") {
                    Picker("Scheme", selection: $manifestConfig.value.scheme) {
                        ForEach(URLScheme.allCases, id: \.rawValue) { scheme in
                            Text(scheme.rawValue)
                        }
                    }
                    .onChange(of: manifestConfig.value.scheme) { _ in
                        ManifestController.shared.setServer(config: manifestConfig.value)
                        Task {
                            self.configs = await getConfigs()
                        }
                    }
                    .pickerStyle(.segmented)
                }

                LabeledContent("Address") {
                    TextField("manifest_address", text: $manifestConfig.value.url, prompt: Text("127.0.0.1"))
                        .keyboardType(.URL)
                        .onChange(of: manifestConfig.value.url) { _ in
                            ManifestController.shared.setServer(config: manifestConfig.value)
                            Task {
                                self.configs = await getConfigs()
                            }
                        }
                }

                LabeledContent("Port") {
                    TextField("manifest_port", value: $manifestConfig.value.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .onChange(of: manifestConfig.value.port) { _ in
                            ManifestController.shared.setServer(config: manifestConfig.value)
                            Task {
                                self.configs = await getConfigs()
                            }
                        }
                }

                LabeledContent("Config") {
                    Picker("Config", selection: $manifestConfig.value.config) {
                        ForEach(self.configs, id: \.self) { config in
                            Text(config)
                        }
                    }
                    .onChange(of: manifestConfig.value.config) { _ in
                        ManifestController.shared.setServer(config: manifestConfig.value)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.columns)
        }
        .task {
            self.configs = await getConfigs()
        }
    }
    
    private func getConfigs() async -> [String] {
        do {
            let configs = try await ManifestController.shared.getConfigs()
            let sorted = configs.sorted { $0.id > $1.id }
            return sorted.reduce(into: [], { $0.append($1.configProfile) })
        } catch {
            print("Failed to fetch manifest configs: \(error.localizedDescription)")
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
