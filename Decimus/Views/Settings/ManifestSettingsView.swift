import SwiftUI

enum URLScheme: String, CaseIterable {
    case http
    case https
}

struct ManifestSettingsView: View {
    @AppStorage("manifestConfig")
    private var manifestConfig: AppStorageWrapper<ManifestServerConfig> = .init(value: .init())

    var body: some View {
        Section("Manifest") {
            Form {
                Picker("Scheme", selection: $manifestConfig.value.scheme) {
                    ForEach(URLScheme.allCases, id: \.rawValue) { scheme in
                        Text(scheme.rawValue)
                    }
                }
                .onChange(of: manifestConfig.value.scheme) { _ in
                    ManifestController.shared.setServer(config: manifestConfig.value)
                }

                LabeledContent("Address") {
                    TextField("manifest_address", text: $manifestConfig.value.url, prompt: Text("127.0.0.1"))
                        .keyboardType(.URL)
                        .onChange(of: manifestConfig.value.url) { _ in
                            ManifestController.shared.setServer(config: manifestConfig.value)
                        }
                }

                LabeledContent("Port") {
                    TextField("manifest_port", value: $manifestConfig.value.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .onChange(of: manifestConfig.value.port) { _ in
                            ManifestController.shared.setServer(config: manifestConfig.value)
                        }
                }
            }
            .formStyle(.columns)
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
