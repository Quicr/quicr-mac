import SwiftUI

struct SettingsView: View {

    var body: some View {
        Form {
            RelaySettingsView()
                .textFieldStyle(.roundedBorder)

            ManifestSettingsView()
                .textFieldStyle(.roundedBorder)

            InfluxSettingsView()
                .textFieldStyle(.roundedBorder)

            SubscriptionSettingsView()
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 500)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
