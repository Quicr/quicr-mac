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
    
    @State
    private var tokenError: String = ""

    private let logger = DecimusLogger(InfluxSettingsView.self)
    static private let plistKey = "INFLUXDB_TOKEN"

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
                    VStack {
                        SecureField("Token", text: self.$token)
                        Text(self.tokenError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.columns)
            .onAppear {
                do {
                    if let token = try Self.tokenStorage.retrieve() {
                        self.token = token
                    } else {
                        self.token = try Self.tokenFromPlist()
                        self.logger.debug("Restored influx token from plist")
                        self.tokenError = ""
                    }
                } catch {
                    let message = "Error fetching influx token: \(error.localizedDescription)"
                    self.tokenError = message
                    self.logger.warning(message)
                }
            }
            .onChange(of: self.token) {
                guard !self.token.isEmpty else { return }
                do {
                    try Self.tokenStorage.store(self.token)
                    self.tokenError = ""
                } catch {
                    let message = "Error storing influx token: \(error.localizedDescription)"
                    self.tokenError = message
                    self.logger.warning(message)
                }
            }
        }
    }

    static func reset() throws {
        UserDefaults.standard.removeObject(forKey: InfluxSettingsView.defaultsKey)
        try Self.tokenStorage.delete()
    }

    static func tokenFromPlist() throws -> String {
        guard let token = Bundle.main.object(forInfoDictionaryKey: Self.plistKey) as? String else {
            throw "Missing \(Self.plistKey) in Info.plist"
        }
        return token
    }
}

struct InfluxSettings_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            InfluxSettingsView()
        }
    }
}
