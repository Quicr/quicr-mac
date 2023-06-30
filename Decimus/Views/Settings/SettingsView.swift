import SwiftUI

struct SettingsView: View {

    var body: some View {
        Form {
            RelaySettingsView()
#if !os(tvOS)
                .textFieldStyle(.roundedBorder)
#endif

            ManifestSettingsView()
#if !os(tvOS)
                .textFieldStyle(.roundedBorder)
#endif

            InfluxSettingsView()
#if !os(tvOS)
                .textFieldStyle(.roundedBorder)
#endif
        }
        .frame(maxWidth: 500)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
