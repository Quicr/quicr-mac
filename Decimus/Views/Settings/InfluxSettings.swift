import SwiftUI

struct InfluxSettings: View {

    @AppStorage("influxConfig") private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

    var body: some View {
        Form {
            Section(header: Text("Influx Connection")) {

                Toggle(isOn: $influxConfig.value.submit) {
                    Text("Submit Metrics")
                }

                LabeledContent {
                    TextField(
                        "Interval (s)",
                        value: $influxConfig.value.intervalSecs,
                        format: .number)
                } label: {
                    Text("Interval (s)")
                }

                LabeledContent {
                    TextField("URL", text: $influxConfig.value.url)
                } label: {
                    Text("URL")
                }

                LabeledContent {
                    TextField("Username", text: $influxConfig.value.username)
                } label: {
                    Text("Username")
                }

                LabeledContent {
                    SecureField("Password", text: $influxConfig.value.password)
                } label: {
                    Text("Password")
                }

                LabeledContent {
                    TextField("Bucket", text: $influxConfig.value.bucket)
                } label: {
                    Text("Bucket")
                }

                LabeledContent {
                    TextField("Org", text: $influxConfig.value.org)
                } label: {
                    Text("Org")
                }

                LabeledContent {
                    SecureField("Token", text: $influxConfig.value.token)
                } label: {
                    Text("Token")
                }
            }
        }
    }
}

struct InfluxSettings_Previews: PreviewProvider {
    static var previews: some View {
        InfluxSettings()
    }
}
