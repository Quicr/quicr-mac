// SPDX-FileCopyrightText: Copyright (c) 2023 Cisco Systems
// SPDX-License-Identifier: BSD-2-Clause

import SwiftUI

struct InfluxSettingsView: View {
    static let defaultsKey = "influxConfig"

    @AppStorage(Self.defaultsKey)
    private var influxConfig: AppStorageWrapper<InfluxConfig> = .init(value: .init())

    private static let tokenStorage = try! TokenStorage(tag: Self.defaultsKey)

    @State
    private var token: String = ""

    private let logger = DecimusLogger(InfluxSettingsView.self)

    var body: some View {
        Section("Influx Connection") {
            Form {
                HStack {
                    HStack {
                        Text("Submit Metrics")
                        Toggle(isOn: $influxConfig.value.submit) {}
                    }
                    HStack {
                        Text("Granular")
                        Toggle(isOn: $influxConfig.value.granular) {}
                    }
                    HStack {
                        Text("Realtime")
                        Toggle(isOn: $influxConfig.value.realtime) {}
                    }
                }

                LabeledContent("Interval (s)") {
                    NumberView(value: $influxConfig.value.intervalSecs,
                               formatStyle: IntegerFormatStyle<Int>.number.grouping(.never),
                               name: "Interval (s)")
                }

                LabeledContent("URL") {
                    TextField("URL", text: $influxConfig.value.url)
                }

                LabeledContent("Bucket") {
                    TextField("Bucket", text: $influxConfig.value.bucket)
                }

                LabeledContent("Org") {
                    TextField("Org", text: $influxConfig.value.org)
                }

                LabeledContent("Token") {
                    SecureField("Token", text: self.$token)
                }
            }
            .formStyle(.columns)
            .onAppear {
                do {
                    if let token = try Self.tokenStorage.retrieve() {
                        self.token = token
                    } else {
                        self.token = ""
                    }
                } catch {
                    self.logger.error("Error fetching influx token: \(error.localizedDescription)")
                }
            }
            .onChange(of: self.token) {
                do {
                    try Self.tokenStorage.store(self.token)
                } catch {
                    self.logger.error("Error storing influx token: \(error.localizedDescription)")
                }
            }
        }
    }

    static func reset() throws {
        UserDefaults.standard.removeObject(forKey: InfluxSettingsView.defaultsKey)
        try Self.tokenStorage.delete()
    }
}

struct InfluxSettings_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            InfluxSettingsView()
        }
    }
}
