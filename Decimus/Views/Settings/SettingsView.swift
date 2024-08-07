import SwiftUI

struct SettingsView: View {

    @State private var cancelConfirmation = false

    @AppStorage("metricsSubmitterType")
    private var metricsSubmitterType: MetricsSubmitterType = .pubSub

    var body: some View {
        // Reset all.
        HStack {
            Spacer()
            let resetString = "Reset to defaults"
            Button(role: .destructive) {
                self.cancelConfirmation = true
            } label: {
                Text(resetString)
            }
            .confirmationDialog(resetString,
                                isPresented: self.$cancelConfirmation) {
                Button("Reset", role: .destructive) {
                    // Reset all settings to defaults.
                    UserDefaults.standard.removeObject(forKey: RelaySettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: ManifestSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: MetricsSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: InfluxSettingsView.defaultsKey)
                    UserDefaults.standard.removeObject(forKey: SubscriptionSettingsView.defaultsKey)
                }
            }
            .buttonStyle(BorderedButtonStyle())
            .padding(.horizontal)
        }

        // Settings.
        Form {
            RelaySettingsView()
                .decimusTextStyle()

            ManifestSettingsView()
                .decimusTextStyle()

            Section("Metrics") {
                Form {
                    Picker("Type", selection: $metricsSubmitterType) {
                        ForEach(MetricsSubmitterType.allCases) {
                            Text($0.rawValue.capitalized)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .formStyle(.columns)

                switch metricsSubmitterType {
                case .pubSub:
                    MetricsSettingsView()
                        .decimusTextStyle()
                case .influx:
                    InfluxSettingsView()
                        .decimusTextStyle()
                }
            }

            SubscriptionSettingsView()
                .decimusTextStyle()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

struct DecimusTextFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
        #if os(tvOS)
            .textFieldStyle(.plain)
        #else
            .textFieldStyle(.roundedBorder)
        #endif
    }
}

extension View {
    func decimusTextStyle() -> some View {
        modifier(DecimusTextFieldStyle())
    }
}
