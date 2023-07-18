import SwiftUI

struct PublicationSettingsView: View {

    @AppStorage("publicationSettings")
    private var publicationSettings: AppStorageWrapper<PublicationSettings> = .init(value: .init(opusWindowSize: 0.01))
    let validWindowSizes: [Double] = [0.0025, 0.005, 0.01, 0.02, 0.04, 0.06]

    var body: some View {
        Section("Publication Settings") {
            Form {
                Picker("Opus Window Size (s)", selection: $publicationSettings.value.opusWindowSize) {
                    ForEach(validWindowSizes, id: \.self) {
                        Text("\(String(format: "%.1f", $0 * 1000))ms")
                    }
                }
            }
            .formStyle(.columns)
        }
    }
}

struct PublicationSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            PublicationSettingsView()
        }
    }
}
